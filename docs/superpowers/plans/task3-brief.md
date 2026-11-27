# Task 3 brief — Core diskpart 清理执行器

## 背景

firpe-cleaner Core 层清理执行器：diskpart `/s` 脚本 `select disk N` + `clean`（仅 clean，无深度清理），解析输出判成功/失败。

## 需求来源

- Spec：`docs/superpowers/specs/2026-11-26-firpe-cleaner-gui-design.md` §4
- Plan：`docs/superpowers/plans/2026-11-26-firpe-cleaner-gui.md` Task 3

## 任务（精确，基于 HEAD=fb3e44a）

### 1. `firpe-cleaner/src/FirpeCleaner.Core/CleanRunner.cs`
- `public sealed class CleanResult`：`bool Success`、`IReadOnlyList<string> Failures`、`string Output`、`int CleanedCount`
- `public CleanResult Run(IEnumerable<int> diskNumbers)`：
  1. 生成 diskpart 脚本到临时文件（`%TEMP%`）：每盘 `select disk N` + `clean`
     （**仅 clean**，无 clean all）
  2. `Process.Start("diskpart", "/s:<脚本路径>")`，WaitForExit + 捕获 stdout/stderr
     （`UseShellExecute=false`、`RedirectStandardOutput/Error`）
  3. 解析输出：含 "DiskPart successfully"（成功）判定该盘成功；错误关键字
     （"There is no disk"/"access denied"/"The disk is in use" 等）判定失败
  4. 临时脚本 finally 删除
  5. 破坏性操作——调用方已确认才调用（本层不弹窗，GUI 负责）

### 2. `firpe-cleaner/tests/FirpeCleaner.Tests/CleanRunnerTests.cs`
- `BuildScript_OneSelectCleanPerDisk()`：断言生成文本为
  `select disk 0\nclean\nselect disk 1\nclean\n`（无 clean all）
- `ParseOutput_DetectsSuccessAndFailure()`：喂含 "DiskPart successfully" 输出→成功；
  喂含 "There is no disk" → 失败
- 脚本生成逻辑抽成可测方法（如 `internal static string BuildScript(IEnumerable<int>)`）

### 3. 验证
- `dotnet test` 全 PASS + build 0 warning

### 4. Commit
`feat(firpe-cleaner): Core diskpart 清理执行器（脚本生成+结果解析，仅 clean）`

## 环境

- dotnet 8 SDK（PATH 或 C:\Program Files\dotnet\dotnet.exe）
- 只改 firpe-cleaner/ 的 Core+Tests

## 禁止

- 不改 GUI；不真 clean 本机盘（测试只测脚本生成与输出解析，不调用 Run 真执行）
- 不 push

## 报告

写 `firpe-cleaner/task3-report.md`：实现说明、测试输出、commit hash。
返回：状态（DONE/BLOCKED）、commit hash、一行摘要、concerns。