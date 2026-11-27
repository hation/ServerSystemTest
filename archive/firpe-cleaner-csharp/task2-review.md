# Task 2 审查报告 — Core 磁盘枚举（WMI 主 + diskpart 回退 + 过滤 + 剩余容量）

日期：2026-11-26
审查对象：commit `daa295c`（HEAD 相对 `849b90e`）
审查范围：`src/FirpeCleaner.Core/DiskInfo.cs`、`src/FirpeCleaner.Core/DiskEnumerator.cs`、`tests/FirpeCleaner.Tests/DiskEnumeratorTests.cs`、Core csproj
结论：**Needs fixes**（1 个 Critical：diskpart 回退解析在真实输出上崩溃，且测试样本掩盖了该缺陷）

---

## 一、合规核对（Spec §4 + brief）

| 检查项 | 结果 | 说明 |
|---|---|---|
| WMI `Win32_DiskDrive` 主策略 | ✅ | `EnumerateByWmi()`，`Index`→`Number`、`Size`→`SizeGB`（Round，AwayFromZero）、`InterfaceType`→`Bus`、`MediaType`→`Media` 映射正确 |
| diskpart 回退（WMI 异常/空列表触发） | ✅ | `Enumerate()` 两处兜底：空列表与异常；临时脚本 + `/s:` 执行 + 输出捕获 + 30s 超时 kill |
| 剩余容量分区归并 | ✅ | `Win32_DiskPartition`(DiskIndex) + `Win32_LogicalDisk`(FreeSpace) + `Win32_LogicalDiskToPartition` 关联映射，按盘号字节求和后一次转 GB；无映射 → `FreeGB=null` |
| 过滤：USB / Removable / CD / DVD / <1GB | ✅ | `Filter()` 逐项标注；系统盘按 brief 口径（WinPE 启动盘=USB 已被 USB 规则排除 + diskpart 回退路径用 `detail disk` "Boot Disk/启动磁盘" 标记排除） |
| 排除盘不丢盘（标注而非删除） | ✅ | `Filter` 只设 `IsExcluded`/`ExcludeReason`，返回完整列表 |
| `[SupportedOSPlatform("windows")]` | ✅ | `DiskEnumerator` 类与测试类均标注 |
| Core 不引用 WPF | ✅ | Core csproj 仅 `System.Management 8.0.0`，无 WPF 引用 |
| 不做清理动作 / 不改 GUI | ✅ | 枚举只读，无 write 操作 |
| 只改 firpe-cleaner/ | ✅ | `git diff 849b90e..daa295c` 全部落在 firpe-cleaner/ 内 |
| 未 push | ✅ | main 领先 origin/main 32 个提交 |
| dotnet test 全 PASS / build 0 warning | ✅ | 复跑确认（见下） |
| 测试真验证行为 | ⚠️ | Filter 测试真验证；Parse 测试**样本不含卷表**，掩盖 Critical 缺陷（见 C1） |

## 二、复跑验证记录

```
dotnet build FirpeCleaner.sln -c Debug → 已成功生成，0 个警告，0 个错误
dotnet test  → 已通过! 失败: 0，通过: 2，已跳过: 0，总计: 2
```

## 三、问题列表

### Critical

**C1 — diskpart 回退解析在真实 `detail disk` 输出上必然崩溃（重复盘号 → ToDictionary 抛异常）**
`DiskEnumerator.cs:343` 的 `DiskRowRegex`（`^\s*(?:Disk|磁盘)\s+(\d+)(?:\s+\S+)*?\s+([\d.]+)\s+(B|KB|MB|GB|TB)`，Multiline）中 `\s` 可跨行、`(?:\s+\S+)*?` 为惰性扩展，会从 `detail disk` 段首的 "磁盘 0"/"Disk 0" 头行跨行匹配到卷表的容量列（真实输出必有卷表，如 "卷 0 ... 550 MB"），产生**重复盘号条目**。

用贴近真实的中文 diskpart 输出（含卷表）实测该正则，得到 4 个匹配（本应只有 3 个 list disk 行）：

```
match#0 => number=0 size=476 unit=GB   ← list disk 行 ✓
match#1 => number=1 size=0   unit=B    ← list disk 行 ✓
match#2 => number=0 size=550 unit=MB   ← ✗ detail 段 "磁盘 0" 头行跨行误匹配到卷行 "550 MB"
match#3 => number=2 size=894 unit=GB   ← ✗ detail 段 "磁盘 2" 头行跨行误匹配到卷行 "894 GB"
```

后果：`ParseDiskpartOutput` 第 93 行 `byNumber = disks.ToDictionary(...)` 遇重复键抛 `ArgumentException`；`EnumerateByDiskpart` 第二次 `RunDiskpart(select+detail)` 即崩，异常从 `Enumerate()` 的 catch 块内直接传出。**diskpart 回退路径在真实机器（任一分区盘）上不可用**，恰是 WinPE 缺 WMI 时唯一路径——回退策略形同虚设。测试样本的 detail 段刻意无卷表（只有 类型/状态/Boot 行），故测试通过、缺陷被掩盖。

修复建议（择一即可）：
1. `DiskRowRegex` 限定只在 list disk 表格段匹配——如要求匹配行位于 "Disk ###/磁盘 ###" 表头之后、或在匹配前排除 `select`/`detail` 段（按 `^select\s+disk` 分段解析，只对 list 段跑行正则）；
2. 或对盘号去重后再建字典（`TryAdd` 或 `ContainsKey` 检查），重复条目丢弃。
配套：单测补充**含卷表**的 detail 输出样本（英文+中文各一），断言不产生重复盘号、`ToDictionary` 不抛。

### Important

**I1 — WMI 主路径不排除系统盘（仅 diskpart 回退路径设置 IsBoot）**
`IsBoot` 只在 `ParseDiskpartOutput` 的 Boot 行置位；WMI 路径恒为 false。故非 PE 桌面直接运行本工具时，WMI 主路径会把系统盘（C: 所在盘）列为可清理、默认勾选。属 brief 明示口径（WinPE 启动盘=USB 已被 USB 规则排除，SAS/SATA 内置盘非系统盘），报告 concern #3 已记录该风险。建议至少：GUI（Task 5）确认弹窗对盘列表做高危提示，或 WMI 路径补 `Win32_OperatingSystem.BootDevice`/启动分区映射做系统盘标注，双保险。

**I2 — Parse 单测样本失真，未覆盖真实卷表场景（C1 的掩盖面）**
测试断言了盘号/大小/Bus 解析（真验证），但样本的 detail 段无卷表，无法暴露 C1；且未断言 `IsBoot`（"Boot Disk : Yes" 行已存在于样本却未断言）。建议：卷表样本 + `Assert.True(disks[0].IsBoot)` + 启动盘过滤用例。

### Minor

**M1 — WMI `Size` 为 null 时 SizeGB=0，被误标"容量小于 1GB"排除**
`DiskEnumerator.cs:183`：`SizeGB = sizeBytes is null ? 0 : ...`，随后 Filter 按 `<1` 排除，原因误标。小概率（正常盘 Size 必有值）；建议空值置 `SizeGB=0` 但排除原因改为"容量未知"或直接不排除。

**M2 — `FreeSpace` null 按 0 计入**
`DiskEnumerator.cs:145`：`logicalFree[id] = GetLong(l, "FreeSpace") ?? 0L`。若盘上映射逻辑盘的 FreeSpace 均 null，`FreeGB` 显示 0 而非 null（口径上 null="拿不到显示—" 更准确）。小概率；可改为空则不计入 `mappedByDisk`。

**M3 — USB 判定为精确等于 "USB"**
UAS（USB Attached SCSI）盘 WMI `InterfaceType` 可能为 "SCSI" 而漏判。属 brief 明确口径（`Bus=="USB"`），仅记录不要求改。

## 四、其他说明（无问题）

- `RoundGiga`（字节→GB，AwayFromZero 舍入）与 `EnumerateByDiskpart` 合并逻辑（SizeGB 以 list disk 为准、Bus/IsBoot 回填）正确。
- `ExtractDeviceId` 解析 `Win32_DiskPartition.DeviceID="Disk #0, Partition #1"` 与 `Win32_LogicalDisk.DeviceID="C:"` 关联键格式正确。
- `RunDiskpart` 临时脚本 finally 清理、超时 kill、`CultureInfo.InvariantCulture` 解析均健壮。
- `MediaIsRemovableOrOptical` 用 Contains("CD"/"DVD"/"Removable")，WMI 标准 MediaType 取值无实际误伤面。
- 本机 WMI 真机输出（1 块 SCSI/YMTC SSD 477GB，Free 234GB，未误排除）与报告一致；diskpart 需提权（740）无法本地实测，与报告一致。

## 五、结论

**Needs fixes**：C1 使 diskpart 回退路径在真实环境必崩（重复盘号 → ToDictionary 异常），且现有单测样本掩盖该缺陷；I1 为已记录的系统盘口径风险，建议 GUI 层兜底。修复 C1（含补卷表单测）后即可合入。
