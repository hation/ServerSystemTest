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
}
