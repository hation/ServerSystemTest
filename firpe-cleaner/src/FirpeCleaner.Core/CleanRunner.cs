using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.Versioning;
using System.Text;

namespace FirpeCleaner.Core;

/// <summary>diskpart 清理执行结果：成功标志/失败明细/原始输出/成功盘数。</summary>
public sealed class CleanResult
{
    /// <summary>是否全部成功（无失败且至少一个盘判定成功；部分失败时亦为 false）。</summary>
    public bool Success { get; init; }

    /// <summary>失败明细（命中的错误行原文，逐条可展示/日志）。</summary>
    public IReadOnlyList<string> Failures { get; init; } = Array.Empty<string>();

    /// <summary>diskpart 原始输出（含脚本回显），供 GUI 展示/日志落盘。</summary>
    public string Output { get; init; } = "";

    /// <summary>判定成功的盘数（命中成功关键字的行数，英文/中文均可）。</summary>
    public int CleanedCount { get; init; }
}

/// <summary>
/// diskpart 清理执行器：每盘 <c>select disk N</c> + <c>clean</c>（仅 clean，无深度清理）
/// 生成脚本到 %TEMP% → <c>diskpart /s</c> 运行并捕获输出 → 解析判定成功/失败。
/// 破坏性操作——仅允许在调用方已取得用户确认后调用（本层不弹窗，确认由 GUI 负责）。
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class CleanRunner
{
    /// <summary>
    /// 成功关键字（英文固定文本 + 中文变体，命中任一行即计成功盘）。
    /// 中文用 "已成功" 精确匹配：覆盖 diskpart 中文版 clean 成功输出（"DiskPart 已成功清除磁盘。"），
    /// 且失败文本（"没有选定磁盘"/"拒绝访问"/"已遇到错误" 等）不含 "已成功"，不会误命中。
    /// </summary>
    private static readonly string[] SuccessMarkers =
    {
        "DiskPart successfully", // diskpart 英文固定文本，与系统语言无关
        "已成功",                 // 中文：diskpart 中文版 clean 成功输出（FirPE 中文 PE 场景）
    };

    /// <summary>失败关键字（英文/中文变体，命中任一行即判定失败；宽松匹配以覆盖 diskpart 真实输出形态）。</summary>
    private static readonly string[] FailureMarkers =
    {
        "There is no disk",            // 盘号不存在（diskpart 输出 "There is no disk selected."）
        "denied",                      // 权限不足（diskpart 英文输出 "Access is denied."，宽松匹配 "denied" 以命中）
        "The disk is in use",          // 磁盘被占用（有卷挂载/系统盘）
        "has encountered an error",    // diskpart 通用错误前缀（"DiskPart has encountered an error: ..."）
        "没有磁盘",                     // 中文：盘不存在
        "没有选定磁盘",                  // 中文：盘号不存在（diskpart 中文输出形态）
        "拒绝访问",                     // 中文：权限不足
        "磁盘正在使用中",                // 中文：磁盘被占用
        "发生错误",                     // 中文：通用错误
        "已遇到错误",                    // 中文：diskpart 通用错误前缀（"DiskPart 已遇到错误: ..."）
    };

    /// <summary>
    /// 执行清理：生成脚本 → diskpart /s 运行 → 解析结果。
    /// 空盘列表直接返回失败（No disks selected，不生成脚本）；脚本写入失败/启动失败/执行超时均以失败结果返回
    /// （错误信息进 Failures 供 GUI 展示）。临时脚本 finally 删除；写失败时 catch 中删除，不留残留。
    /// </summary>
    public CleanResult Run(IEnumerable<int> diskNumbers)
    {
        var disks = (diskNumbers ?? Array.Empty<int>()).ToList();
        if (disks.Count == 0)
        {
            return new CleanResult { Failures = new[] { "No disks selected" } };
        }

        var script = BuildScript(disks);
        var scriptFile = Path.Combine(Path.GetTempPath(), "firpe-clean-" + Guid.NewGuid().ToString("N")[..8] + ".txt");
        try
        {
            File.WriteAllText(scriptFile, script);
        }
        catch (Exception ex)
        {
            // 写失败：删除可能残留的半写临时脚本，返回失败结果
            TryDelete(scriptFile);
            return new CleanResult { Failures = new[] { $"写入临时脚本失败: {ex.Message}" } };
        }

        try
        {
            var output = RunDiskpart(scriptFile);
            return ParseOutput(output);
        }
        catch (InvalidOperationException ex)
        {
            // diskpart 缺失/启动失败/执行超时 → 明确错误信息进 Failures，以失败结果返回
            return new CleanResult { Failures = new[] { ex.Message } };
        }
        finally
        {
            TryDelete(scriptFile);
        }
    }

    private static void TryDelete(string scriptFile)
    {
        try { File.Delete(scriptFile); } catch { /* 临时脚本删除失败不影响清理结果 */ }
    }

    /// <summary>生成 diskpart 脚本：每盘 <c>select disk N</c> + <c>clean</c>（仅 clean，无 clean all）。</summary>
    internal static string BuildScript(IEnumerable<int> diskNumbers)
    {
        var sb = new StringBuilder();
        foreach (var number in diskNumbers)
        {
            sb.Append("select disk ").Append(number).AppendLine();
            sb.AppendLine("clean");
        }
        return sb.ToString();
    }

    /// <summary>解析 diskpart 输出：命中成功关键字计成功盘；命中任一失败关键字计失败。</summary>
    internal static CleanResult ParseOutput(string output)
    {
        if (string.IsNullOrEmpty(output)) return new CleanResult();

        var cleanedCount = 0;
        var failures = new List<string>();
        foreach (var rawLine in output.Split('\n'))
        {
            var line = rawLine.TrimEnd('\r');
            if (line.Length == 0) continue;
            if (ContainsAnySuccessMarker(line))
            {
                cleanedCount++;
            }
            else if (ContainsAnyFailureMarker(line))
            {
                failures.Add(line.Trim());
            }
        }
        return new CleanResult
        {
            Success = cleanedCount > 0 && failures.Count == 0,
            Failures = failures,
            Output = output,
            CleanedCount = cleanedCount,
        };
    }

    private static bool ContainsAnySuccessMarker(string line)
    {
        foreach (var marker in SuccessMarkers)
        {
            if (line.Contains(marker, StringComparison.OrdinalIgnoreCase)) return true;
        }
        return false;
    }

    private static bool ContainsAnyFailureMarker(string line)
    {
        foreach (var marker in FailureMarkers)
        {
            if (line.Contains(marker, StringComparison.OrdinalIgnoreCase)) return true;
        }
        return false;
    }

    /// <summary>调用 diskpart /s 执行脚本并捕获输出，30s 超时杀进程。</summary>
    private static string RunDiskpart(string scriptFile)
    {
        return RunProcess("diskpart", "/s \"" + scriptFile + "\"", 30_000);
    }

    /// <summary>
    /// 运行外部进程并捕获 stdout/stderr（stderr 并入输出供解析）。
    /// 异步读（BeginOutputReadLine/BeginErrorReadLine）避免同步顺序读 stdout→stderr 的管道缓冲死锁；
    /// WaitForExit(timeout) 判定超时 → Kill() 强制终止，确保超时分支真正可达。
    /// </summary>
    internal static string RunProcess(string fileName, string arguments, int timeoutMs)
    {
        var psi = new ProcessStartInfo
        {
            FileName = fileName,
            Arguments = arguments,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };

        Process p;
        try
        {
            p = Process.Start(psi) ?? throw new InvalidOperationException("进程启动失败: " + fileName);
        }
        catch (Win32Exception ex)
        {
            // diskpart 缺失/不在 PATH 等启动失败 → 包装为明确错误信息（含原始原因）
            throw new InvalidOperationException($"无法启动 {fileName}（可能未安装或不在 PATH）: {ex.Message}", ex);
        }

        using (p)
        {
            var stdout = new StringBuilder();
            var stderr = new StringBuilder();
            p.OutputDataReceived += (_, e) => { if (e.Data != null) stdout.AppendLine(e.Data); };
            p.ErrorDataReceived += (_, e) => { if (e.Data != null) stderr.AppendLine(e.Data); };
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();

            if (!p.WaitForExit(timeoutMs))
            {
                try { p.Kill(); } catch { /* 超时瞬间进程恰好已退出，忽略 */ }
                p.WaitForExit(); // 等待进程退出并排空异步读事件
                throw new InvalidOperationException($"{fileName} 执行超时（已强制终止）");
            }
            // 无参 WaitForExit：确保异步输出事件全部处理完成（.NET 文档要求，否则输出可能不完整）
            p.WaitForExit();

            var errorText = stderr.ToString();
            return string.IsNullOrEmpty(errorText) ? stdout.ToString() : stdout + Environment.NewLine + errorText;
        }
    }
}
