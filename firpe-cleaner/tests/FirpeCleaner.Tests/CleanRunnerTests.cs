using System.Diagnostics;
using System.Runtime.Versioning;
using FirpeCleaner.Core;

namespace FirpeCleaner.Tests;

[SupportedOSPlatform("windows")]
public class CleanRunnerTests
{
    [Fact]
    public void BuildScript_OneSelectCleanPerDisk()
    {
        var script = CleanRunner.BuildScript(new[] { 0, 1 });

        // 每盘一行 select disk N + 一行 clean，且仅 clean（无 clean all）
        Assert.Equal(
            "select disk 0" + Environment.NewLine + "clean" + Environment.NewLine +
            "select disk 1" + Environment.NewLine + "clean" + Environment.NewLine,
            script);
        Assert.DoesNotContain("clean all", script, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ParseOutput_DetectsSuccessAndFailure()
    {
        // 成功输出：含 "DiskPart successfully"（diskpart 英文固定文本）→ 成功，成功盘数 1
        var ok = CleanRunner.ParseOutput("""
            Microsoft DiskPart 版本 10.0.22621.1
            select disk 0
            DiskPart successfully cleaned the disk.
            """);
        Assert.True(ok.Success);
        Assert.Equal(1, ok.CleanedCount);
        Assert.Empty(ok.Failures);

        // 失败输出：含 "There is no disk" 错误关键字 → 失败，失败明细非空
        var fail = CleanRunner.ParseOutput("""
            Microsoft DiskPart 版本 10.0.22621.1
            select disk 5
            There is no disk selected.
            """);
        Assert.False(fail.Success);
        Assert.Equal(0, fail.CleanedCount);
        Assert.NotEmpty(fail.Failures);
        Assert.Contains("There is no disk", string.Join(Environment.NewLine, fail.Failures));

        // 混合输出：盘 0 成功、盘 1 失败（The disk is in use）→ 整体失败但成功盘数保留
        var mixed = CleanRunner.ParseOutput("""
            select disk 0
            DiskPart successfully cleaned the disk.
            select disk 1
            The disk is in use.
            """);
        Assert.False(mixed.Success);
        Assert.Equal(1, mixed.CleanedCount);
        Assert.Contains("The disk is in use", string.Join(Environment.NewLine, mixed.Failures));
    }

    [Fact]
    public void ParseOutput_DetectsAccessDenied()
    {
        // diskpart 权限不足的真实输出 "Access is denied."（裸输出，无通用错误前缀）→ 宽松匹配 "denied" 判定失败
        var fail = CleanRunner.ParseOutput("""
            Microsoft DiskPart 版本 10.0.22621.1
            select disk 0
            Access is denied.
            """);
        Assert.False(fail.Success);
        Assert.Equal(0, fail.CleanedCount);
        Assert.NotEmpty(fail.Failures);
        Assert.Contains("Access is denied", string.Join(Environment.NewLine, fail.Failures));

        // 变体 "Access denied."（无 is）同样命中
        var variant = CleanRunner.ParseOutput("""
            select disk 1
            DiskPart has encountered an error: Access denied.
            """);
        Assert.False(variant.Success);
        Assert.NotEmpty(variant.Failures);
    }

    [Fact]
    public void RunProcess_TimeoutKillsHungProcess()
    {
        // 挂起进程（ping 长时长运行）验证超时杀路径：异步读 + WaitForExit(timeout) 判定 + Kill 强制终止；
        // 仅测进程管理逻辑，不涉及 diskpart/clean
        var sw = Stopwatch.StartNew();
        var ex = Assert.Throws<InvalidOperationException>(
            () => CleanRunner.RunProcess("ping", "127.0.0.1 -n 100", 1500));
        sw.Stop();

        Assert.Contains("超时", ex.Message);
        // 耗时应达到超时阈值（走超时分支而非进程正常退出后读到 EOF）
        Assert.True(sw.ElapsedMilliseconds >= 1400,
            $"应走超时分支，实际耗时 {sw.ElapsedMilliseconds}ms 不足超时阈值");
    }

    [Fact]
    public void Run_EmptyDiskList_ReturnsFailureNoDisksSelected()
    {
        // 空盘列表 → 失败结果 + No disks selected，不生成脚本、不调用 diskpart
        var result = new CleanRunner().Run(Array.Empty<int>());
        Assert.False(result.Success);
        Assert.Contains("No disks selected", result.Failures);
        Assert.Equal(0, result.CleanedCount);
    }
}
