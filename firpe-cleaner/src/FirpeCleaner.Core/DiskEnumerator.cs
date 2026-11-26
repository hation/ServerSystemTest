using System.Diagnostics;
using System.Globalization;
using System.Management;
using System.Runtime.Versioning;
using System.Text;
using System.Text.RegularExpressions;

namespace FirpeCleaner.Core;

/// <summary>
/// 磁盘枚举：WMI <c>Win32_DiskDrive</c> 主策略（含分区归并剩余容量），
/// WMI 不可用时回退 diskpart <c>list disk</c>+<c>detail disk</c> 解析；
/// 结果含排除标记（USB/CD/系统盘/&lt;1GB），只读枚举，不做任何清理动作。
/// </summary>
[SupportedOSPlatform("windows")]
public static partial class DiskEnumerator
{
    private const long OneGigaByte = 1024L * 1024 * 1024;

    /// <summary>枚举本机物理磁盘（已按过滤规则标注排除）。</summary>
    public static IReadOnlyList<DiskInfo> Enumerate()
    {
        List<DiskInfo> disks;
        try
        {
            disks = EnumerateByWmi();
            if (disks.Count == 0)
            {
                // WMI 可用但返回空：回退 diskpart 兜底（WinPE 部分 WMI 组件缺失可能静默返回空）
                disks = EnumerateByDiskpart();
            }
        }
        catch (Exception)
        {
            // WMI 不可用（WinPE 缺 WinPE-WMI 组件，典型抛 ManagementException）→ 回退 diskpart
            disks = EnumerateByDiskpart();
        }

        Filter(disks);
        return disks;
    }

    /// <summary>按过滤规则标注排除：USB 总线、Removable/CD/DVD 介质、启动盘（系统盘）、容量&lt;1GB。</summary>
    public static void Filter(IReadOnlyList<DiskInfo> disks)
    {
        foreach (var disk in disks)
        {
            if (disk.IsBoot)
            {
                MarkExcluded(disk, "系统盘（启动盘）");
                continue;
            }
            if (BusIsUsb(disk.Bus))
            {
                MarkExcluded(disk, "USB 移动盘");
                continue;
            }
            if (MediaIsRemovableOrOptical(disk.Media))
            {
                MarkExcluded(disk, "可移动/CD/DVD 介质");
                continue;
            }
            if (disk.SizeUnknown)
            {
                // 容量拿不到（WMI Size 为 null）：标注未知而非误标"容量小于 1GB"
                MarkExcluded(disk, "容量未知");
                continue;
            }
            if (disk.SizeGB < 1)
            {
                MarkExcluded(disk, "容量小于 1GB");
                continue;
            }
        }
    }

    /// <summary>解析 diskpart 输出（<c>list disk</c> + 可选 <c>detail disk</c>），提取盘号/总容量/总线/启动标记。</summary>
    public static List<DiskInfo> ParseDiskpartOutput(string output)
    {
        var disks = new List<DiskInfo>();
        if (string.IsNullOrWhiteSpace(output)) return disks;

        var byNumber = new Dictionary<int, DiskInfo>();
        var current = -1;      // detail 段当前盘号（由脚本命令回显 "select disk N" 定位）
        var inDetail = false;  // 进入 detail 段后不再匹配盘行，杜绝跨段误匹配

        foreach (var rawLine in output.Split('\n'))
        {
            var line = rawLine.TrimEnd('\r');
            if (line.Length == 0) continue;

            // 脚本命令回显（英文 "select disk N"，与系统语言无关）
            var sel = SelectDiskRegex().Match(line);
            if (sel.Success)
            {
                current = int.Parse(sel.Groups[1].Value, CultureInfo.InvariantCulture);
                inDetail = true;
                if (!byNumber.ContainsKey(current))
                {
                    // 纯 detail 输出（无 list 段）也按 select 回显创建条目，保证 Bus/IsBoot 可被提取（调用方按盘号合并）
                    var created = new DiskInfo { Number = current, Device = @"\\.\PhysicalDrive" + current };
                    disks.Add(created);
                    byNumber[current] = created;
                }
                continue;
            }

            if (!inDetail)
            {
                // 仅 list disk 表段匹配盘行（正则已行内锚定，不会跨行误匹配到 detail 段卷表）
                var row = DiskRowRegex().Match(line);
                if (!row.Success) continue;
                var number = int.Parse(row.Groups[1].Value, CultureInfo.InvariantCulture);
                if (byNumber.ContainsKey(number)) continue; // 防御：同盘号重复行丢弃，避免后续字典构建崩溃
                var size = double.Parse(row.Groups[2].Value, CultureInfo.InvariantCulture);
                var unitBytes = UnitToBytes(row.Groups[3].Value);
                disks.Add(new DiskInfo
                {
                    Number = number,
                    Device = @"\\.\PhysicalDrive" + number,
                    SizeGB = RoundGiga((long)(size * unitBytes)),
                });
                byNumber[number] = disks[^1];
                continue;
            }

            // detail 段：取 Type/启动磁盘
            if (current < 0 || !byNumber.ContainsKey(current)) continue;
            var t = TypeLineRegex().Match(line);
            if (t.Success) byNumber[current].Bus = t.Groups[1].Value.Trim();
            var b = BootLineRegex().Match(line);
            if (b.Success && (b.Groups[1].Value.Equals("Yes", StringComparison.OrdinalIgnoreCase) ||
                              b.Groups[1].Value == "是"))
                byNumber[current].IsBoot = true;
        }
        return disks;
    }

    // ---------------- WMI 主策略 ----------------

    private static List<DiskInfo> EnumerateByWmi()
    {
        // 一次性取齐分区/逻辑盘/关联映射，避免逐盘多次 WMI 往返
        var partitions = QueryAll("SELECT * FROM Win32_DiskPartition");       // DeviceID, DiskIndex
        var logicals = QueryAll("SELECT * FROM Win32_LogicalDisk");           // DeviceID, FreeSpace
        var associations = QueryAll("SELECT * FROM Win32_LogicalDiskToPartition"); // Antecedent, Dependent

        // 分区 DeviceID → 逻辑盘 DeviceID（Win32_LogicalDiskToPartition 关联）
        var partToLogical = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var a in associations)
        {
            var part = ExtractDeviceId(GetString(a, "Antecedent"));
            var logical = ExtractDeviceId(GetString(a, "Dependent"));
            if (part.Length > 0 && logical.Length > 0) partToLogical[part] = logical;
        }

        // 逻辑盘 DeviceID → FreeSpace（字节）；FreeSpace 为 null 时不录入，避免归并时按 0 计入
        var logicalFree = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        foreach (var l in logicals)
        {
            var id = GetString(l, "DeviceID");
            var free = GetLong(l, "FreeSpace");
            if (id.Length > 0 && free is not null) logicalFree[id] = free.Value;
        }

        // 系统盘判定：BootPartition=True 的逻辑盘（通常 C:）→ 经 Win32_LogicalDiskToPartition 关联
        // 反查所在分区 → DiskIndex → 物理盘号；该盘在 Filter 中按系统盘排除（非 PE 桌面运行时系统盘不可清理）
        var systemDiskIndex = -1;
        foreach (var l in logicals)
        {
            if (GetBool(l, "BootPartition") is not true) continue;
            var logicalId = GetString(l, "DeviceID");
            foreach (var p in partitions)
            {
                var partId = GetString(p, "DeviceID");
                if (partToLogical.TryGetValue(partId, out var mapped) &&
                    string.Equals(mapped, logicalId, StringComparison.OrdinalIgnoreCase))
                {
                    systemDiskIndex = GetInt(p, "DiskIndex") ?? -1;
                    break;
                }
            }
            if (systemDiskIndex >= 0) break;
        }

        // 按 DiskIndex 归并各盘已分配分区的剩余容量；无分区或无逻辑盘映射 → 该盘 FreeGB=null
        var freeByDisk = new Dictionary<int, long>();
        var mappedByDisk = new HashSet<int>();
        foreach (var p in partitions)
        {
            var diskIndex = GetInt(p, "DiskIndex") ?? -1;
            if (diskIndex < 0) continue;
            var partId = GetString(p, "DeviceID");
            if (partToLogical.TryGetValue(partId, out var logicalId) &&
                logicalFree.TryGetValue(logicalId, out var free))
            {
                freeByDisk[diskIndex] = freeByDisk.GetValueOrDefault(diskIndex) + free;
                mappedByDisk.Add(diskIndex);
            }
        }

        var result = new List<DiskInfo>();
        using (var searcher = new ManagementObjectSearcher("SELECT * FROM Win32_DiskDrive"))
        using (var collection = searcher.Get())
        {
            foreach (ManagementObject mo in collection)
            {
                using (mo)
                {
                    var number = GetInt(mo, "Index") ?? -1;
                    if (number < 0) continue;
                    var bus = GetString(mo, "InterfaceType");
                    var media = GetString(mo, "MediaType");
                    var sizeBytes = GetLong(mo, "Size");
                    result.Add(new DiskInfo
                    {
                        Number = number,
                        Device = @"\\.\PhysicalDrive" + number,
                        Sn = GetString(mo, "SerialNumber"),
                        Model = GetString(mo, "Model"),
                        // Size 为 null 时置 SizeUnknown，Filter 标注"容量未知"而非误标 <1GB
                        SizeGB = sizeBytes is null ? 0 : RoundGiga(sizeBytes.Value),
                        SizeUnknown = sizeBytes is null,
                        FreeGB = mappedByDisk.Contains(number) ? RoundGiga(freeByDisk[number]) : null,
                        Bus = bus,
                        Media = media,
                        IsHdd = media.Contains("HDD", StringComparison.OrdinalIgnoreCase) ||
                                bus.Equals("SAS", StringComparison.OrdinalIgnoreCase),
                        IsBoot = number == systemDiskIndex,
                    });
                }
            }
        }
        return result;
    }

    private static List<ManagementObject> QueryAll(string wql)
    {
        var list = new List<ManagementObject>();
        using var searcher = new ManagementObjectSearcher(wql);
        using var collection = searcher.Get();
        foreach (ManagementObject mo in collection) list.Add(mo);
        return list;
    }

    // ---------------- diskpart 回退 ----------------

    private static List<DiskInfo> EnumerateByDiskpart()
    {
        // 第一步：list disk 拿盘号/总容量
        var listOutput = RunDiskpart("list disk");
        var disks = ParseDiskpartOutput(listOutput);
        if (disks.Count == 0) return disks;

        // 第二步：逐盘 select disk N + detail disk 拿总线（Type）与启动标记（Boot Disk）
        var sb = new StringBuilder();
        foreach (var d in disks)
        {
            sb.Append("select disk ").Append(d.Number).AppendLine();
            sb.AppendLine("detail disk");
        }
        var detailOutput = RunDiskpart(sb.ToString());
        var detail = ParseDiskpartOutput(detailOutput);
        // detail 结果按盘号合并回 list disk 结果（补 Bus/IsBoot，SizeGB 以 list disk 为准）
        for (var i = 0; i < disks.Count; i++)
        {
            var match = detail.FirstOrDefault(x => x.Number == disks[i].Number);
            if (match == null) continue;
            disks[i] = new DiskInfo
            {
                Number = disks[i].Number,
                Device = disks[i].Device,
                Sn = disks[i].Sn,
                Model = disks[i].Model,
                SizeGB = disks[i].SizeGB,
                FreeGB = disks[i].FreeGB,
                Bus = match.Bus,
                Media = disks[i].Media,
                IsHdd = disks[i].IsHdd,
                IsBoot = match.IsBoot,
            };
        }
        return disks;
    }

    private static string RunDiskpart(string script)
    {
        var scriptFile = Path.Combine(Path.GetTempPath(), "firpe-diskpart-" + Guid.NewGuid().ToString("N")[..8] + ".txt");
        File.WriteAllText(scriptFile, script);
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "diskpart",
                Arguments = "/s \"" + scriptFile + "\"",
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            };
            using var p = Process.Start(psi) ?? throw new InvalidOperationException("diskpart 启动失败");
            var output = p.StandardOutput.ReadToEnd();
            p.StandardError.ReadToEnd();
            if (!p.WaitForExit(30_000))
            {
                p.Kill();
                throw new InvalidOperationException("diskpart 执行超时");
            }
            return output;
        }
        finally
        {
            try { File.Delete(scriptFile); } catch { /* 临时脚本删除失败不影响枚举 */ }
        }
    }

    // ---------------- 通用小工具 ----------------

    private static void MarkExcluded(DiskInfo disk, string reason)
    {
        disk.IsExcluded = true;
        disk.ExcludeReason = reason;
    }

    private static bool MediaIsRemovableOrOptical(string media)
    {
        if (string.IsNullOrEmpty(media)) return false;
        return media.Contains("Removable", StringComparison.OrdinalIgnoreCase) ||
               media.Contains("CD", StringComparison.OrdinalIgnoreCase) ||
               media.Contains("DVD", StringComparison.OrdinalIgnoreCase);
    }

    // USB 判定：不区分大小写包含匹配，覆盖 UAS（InterfaceType 为 "USB" 或含 USB 前缀）等变体
    private static bool BusIsUsb(string bus) =>
        !string.IsNullOrEmpty(bus) && bus.Contains("USB", StringComparison.OrdinalIgnoreCase);

    private static long RoundGiga(long bytes) =>
        (long)Math.Round(bytes / (double)OneGigaByte, MidpointRounding.AwayFromZero);

    private static long UnitToBytes(string unit) => unit.ToUpperInvariant() switch
    {
        "B" => 1L,
        "KB" => 1024L,
        "MB" => 1024L * 1024,
        "GB" => OneGigaByte,
        "TB" => OneGigaByte * 1024,
        _ => 0L,
    };

    private static string GetString(ManagementBaseObject mo, string key)
    {
        var value = mo[key];
        switch (value)
        {
            case null: return "";
            case string s: return s.Trim();
            case Array arr when arr.Length > 0: return arr.GetValue(0)?.ToString()?.Trim() ?? "";
            default: return value.ToString()?.Trim() ?? "";
        }
    }

    private static long? GetLong(ManagementBaseObject mo, string key)
    {
        var value = mo[key];
        if (value == null) return null;
        try { return Convert.ToInt64(value); } catch { return null; }
    }

    private static int? GetInt(ManagementBaseObject mo, string key)
    {
        var value = mo[key];
        if (value == null) return null;
        try { return Convert.ToInt32(value); } catch { return null; }
    }

    private static bool? GetBool(ManagementBaseObject mo, string key)
    {
        var value = mo[key];
        if (value == null) return null;
        try { return Convert.ToBoolean(value); } catch { return null; }
    }

    /// <summary>从 WMI 引用字符串（如 Win32_DiskPartition.DeviceID="Disk #0, Partition #1"）提取 DeviceID。</summary>
    private static string ExtractDeviceId(string refStr)
    {
        const string marker = "DeviceID=\"";
        var start = refStr.IndexOf(marker, StringComparison.OrdinalIgnoreCase);
        if (start < 0) return "";
        start += marker.Length;
        var end = refStr.IndexOf('"', start);
        return end < 0 ? refStr[start..] : refStr[start..end];
    }

    // list disk 行：盘号+大小+单位（英文 Disk / 中文 磁盘；状态列可能是多词如 "No Media"）。
    // 仅用 [ \t] 与 [^\r\n] 做行内锚定、且只在 list 表段内匹配（见 ParseDiskpartOutput），杜绝跨行误匹配到 detail 段卷表
    [GeneratedRegex(@"^[ \t]*(?:Disk|磁盘)[ \t]+(\d+)[ \t]+[^\r\n]*?[ \t]+([\d.]+)[ \t]+(B|KB|MB|GB|TB)", RegexOptions.Multiline)]
    private static partial Regex DiskRowRegex();

    // 脚本命令回显（脚本内容为英文 "select disk N"，与系统语言无关）
    [GeneratedRegex(@"^\s*select\s+disk\s+(\d+)", RegexOptions.IgnoreCase | RegexOptions.Multiline)]
    private static partial Regex SelectDiskRegex();

    // detail disk 的总线行（英文 Type / 中文 类型）
    [GeneratedRegex(@"^\s*(?:Type|类型)\s*:\s*(.+)$", RegexOptions.IgnoreCase | RegexOptions.Multiline)]
    private static partial Regex TypeLineRegex();

    // detail disk 的启动标记行（英文 Boot Disk / 中文 启动磁盘，值为 Yes/是）
    [GeneratedRegex(@"^\s*(?:Boot Disk|启动磁盘)\s*:\s*(Yes|是|No|否)", RegexOptions.IgnoreCase | RegexOptions.Multiline)]
    private static partial Regex BootLineRegex();
}
