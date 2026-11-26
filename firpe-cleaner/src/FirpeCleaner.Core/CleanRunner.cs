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

    /// <summary>判定成功的盘数（"DiskPart successfully" 命中行数）。</summary>
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
    /// <summary>成功关键字（diskpart 英文固定文本，与系统语言无关）。</summary>
    internal const string SuccessMarker = "DiskPart successfully";

    /// <summary>失败关键字（英文/中文变体，命中任一行即判定失败）。</summary>
    private static readonly string[] FailureMarkers =
    {
        "There is no disk",            // 指定盘号不存在
        "access denied",               // 权限不足（未提权/被保护）
        "The disk is in use",          // 磁盘被占用（有卷挂载/系统盘）
        "has encountered an error",    // diskpart 通用错误前缀
        "没有磁盘",                     // 中文：盘不存在
        "拒绝访问",                     // 中文：权限不足
        "磁盘正在使用中",                // 中文：磁盘被占用
        "发生错误",                     // 中文：通用错误
    };

    /// <summary>
    /// 执行清理：生成脚本 → diskpart /s 运行 → 解析结果。临时脚本 finally 删除。
    /// </summary>
    public CleanResult Run(IEnumerable<int> diskNumbers)
    {
        var script = BuildScript(diskNumbers ?? Array.Empty<int>());
        var scriptFile = Path.Combine(Path.GetTempPath(), "firpe-clean-" + Guid.NewGuid().ToString("N")[..8] + ".txt");
        File.WriteAllText(scriptFile, script);
        try
        {
            var output = RunDiskpart(scriptFile);
            return ParseOutput(output);
        }
        finally
        {
            try { File.Delete(scriptFile); } catch { /* 临时脚本删除失败不影响清理结果 */ }
        }
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

    /// <summary>解析 diskpart 输出：命中 SuccessMarker 计成功盘；命中任一失败关键字计失败。</summary>
    internal static CleanResult ParseOutput(string output)
    {
        if (string.IsNullOrEmpty(output)) return new CleanResult();

        var cleanedCount = 0;
        var failures = new List<string>();
        foreach (var rawLine in output.Split('\n'))
        {
            var line = rawLine.TrimEnd('\r');
            if (line.Length == 0) continue;
            if (line.Contains(SuccessMarker, StringComparison.OrdinalIgnoreCase))
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

    private static bool ContainsAnyFailureMarker(string line)
    {
        foreach (var marker in FailureMarkers)
        {
            if (line.Contains(marker, StringComparison.OrdinalIgnoreCase)) return true;
        }
        return false;
    }

    /// <summary>调用 diskpart /s 执行脚本并捕获输出（stderr 并入输出供解析），超时杀进程。</summary>
    private static string RunDiskpart(string scriptFile)
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
        var error = p.StandardError.ReadToEnd();
        if (!p.WaitForExit(30_000))
        {
            p.Kill();
            throw new InvalidOperationException("diskpart 执行超时");
        }
        return string.IsNullOrEmpty(error) ? output : output + Environment.NewLine + error;
    }
}
