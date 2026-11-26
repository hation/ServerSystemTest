# Task 3 报告 — Core diskpart 清理执行器

日期：2026-11-26
状态：**DONE**
Commit：`d408ca4`
（仅改动 `firpe-cleaner/` 的 Core 与 Tests，未 push）

## 一、实现说明

### `src/FirpeCleaner.Core/CleanRunner.cs`（新增）
- **`CleanResult`**：`bool Success`（无失败且至少一个盘判定成功；部分失败亦为 false）、`IReadOnlyList<string> Failures`（命中错误关键字行原文）、`string Output`（diskpart 原始输出）、`int CleanedCount`（"DiskPart successfully" 命中行数）。
- **`Run(IEnumerable<int> diskNumbers)`**：
  1. `BuildScript` 生成脚本到 `%TEMP%`（`firpe-clean-{guid8}.txt`），每盘 `select disk N` + `clean`（**仅 clean，无 clean all**）。
  2. `Process.Start("diskpart", "/s \"path\"")`，`UseShellExecute=false` + `RedirectStandardOutput/Error`，`WaitForExit(30s)` 超时杀进程；stderr 并入输出供解析。
  3. `ParseOutput` 逐行解析；临时脚本 **finally 删除**。
  4. 破坏性操作——本层不弹窗，确认由 GUI 负责。
- **`internal static string BuildScript`** / **`internal static string ParseOutput`** 抽成可测方法（Core csproj 已有 `InternalsVisibleTo("FirpeCleaner.Tests")`）。
- 成功关键字 `DiskPart successfully`（英文固定文本，与系统语言无关）；失败关键字中英双语变体：`There is no disk`/`access denied`/`The disk is in use`/`has encountered an error` + 中文"没有磁盘/拒绝访问/磁盘正在使用中/发生错误"。
- `[SupportedOSPlatform("windows")]` 沿用（与 DiskEnumerator 一致）。

## 二、测试

`tests/FirpeCleaner.Tests/CleanRunnerTests.cs`（新增，**只测脚本生成与输出解析，不调用 `Run` 真执行**，防真 clean 本机盘）：
- `BuildScript_OneSelectCleanPerDisk`：断言脚本精确为 `select disk 0\nclean\nselect disk 1\nclean\n`（换行用 `Environment.NewLine`），且不含 `clean all`。
- `ParseOutput_DetectsSuccessAndFailure`：含 "DiskPart successfully" → Success=true/CleanedCount=1；含 "There is no disk" → Success=false/Failures 非空；混合输出（盘 0 成功 + 盘 1 "The disk is in use"）→ 整体失败但保留成功盘数。

## 三、测试输出

```
dotnet build FirpeCleaner.sln -c Debug
已成功生成。 0 个警告  0 个错误

dotnet test FirpeCleaner.sln -c Debug
已通过! - 失败: 0，通过: 8，已跳过: 0，总计: 8，持续时间: 20 ms - FirpeCleaner.Tests.dll (net8.0)
```

## 四、Commit

```
feat(firpe-cleaner): Core diskpart 清理执行器（脚本生成+结果解析，仅 clean）
```

## 五、Concerns

- `Run` 真执行路径（diskpart 启动/超时/真实输出）依赖管理员权限与真实磁盘环境，本机不真 clean，无法端到端实测；脚本生成与输出解析已由单测覆盖。
- 中文 diskpart 输出的成功文本为本地化字符串（"DiskPart 已成功…"），当前成功判定仅认英文固定文本 `DiskPart successfully`——WinPE 默认英文 diskpart 可命中；若需覆盖中文系统，后续可补中文成功关键字。
