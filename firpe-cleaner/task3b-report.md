# Task 3b Report — CleanRunner review 问题修复

日期：2026-11-26
范围：`firpe-cleaner/` Core + Tests（`CleanRunner.cs` / `CleanRunnerTests.cs` / 本报告）

## 修复说明

依据 `task3-review.md` 的 2 Important + 相关 Minor 问题清单，修复如下：

### Important 1：失败关键字宽松匹配（access denied 命中失败）
- 原 `"access denied"` 无法命中 diskpart 真实输出 `Access is denied.`（中间隔 `is `）。
- 改为宽松关键字 `"denied"`（diskpart 输出中 denied 仅出现在权限拒绝场景，无误伤）。
- 同步核查其他错误关键字真实输出形态：
  - `There is no disk` → 命中 `There is no disk selected.` ✅（前缀匹配）
  - `The disk is in use` → 命中 `The disk is in use.` / `...in use by another process.` ✅
  - `has encountered an error` → 命中 `DiskPart has encountered an error: ...` ✅
  - 中文补强：新增 `没有选定磁盘`（中文盘号不存在输出形态）、`已遇到错误`（中文 diskpart 通用错误前缀 `DiskPart 已遇到错误: ...`），与既有 `没有磁盘`/`拒绝访问`/`磁盘正在使用中`/`发生错误` 互补。

### Important 2：RunDiskpart 异步读 + 超时杀（消除超时不可达与管道死锁）
- 原实现 `ReadToEnd()` 同步阻塞先于 `WaitForExit(30s)`，diskpart 挂起时超时分支不可达，且同步顺序读 stdout→stderr 为经典管道缓冲死锁模式。
- 改为 `BeginOutputReadLine` / `BeginErrorReadLine` 异步读（事件收集 stdout/stderr）→ `WaitForExit(timeout)` 判定 → 超时 `Kill()` + `WaitForExit()` 排空异步事件后抛超时异常；正常路径在 `WaitForExit(timeout)` 返回 true 后补一次无参 `WaitForExit()`（.NET 文档要求，确保异步输出事件处理完成）。
- 抽取 `internal static RunProcess(fileName, arguments, timeoutMs)`，diskpart 走 `RunProcess("diskpart", "/s ...", 30_000)`，使超时杀路径可直接测试（不触碰 diskpart/clean）。

### Minor
1. `File.WriteAllText` 移入 try：写失败时 catch 中删除可能残留的半写临时脚本，并以失败结果返回（`写入临时脚本失败: ...` 进 Failures）。
2. diskpart 缺失：`Process.Start` 的 `Win32Exception` 包装为明确错误 `无法启动 diskpart（可能未安装或不在 PATH）: ...`（进 Failures 而非裸异常）。
3. 空盘列表：`Run` 直接返回 `Success=false` + `Failures["No disks selected"]`，不生成脚本、不调用 diskpart。
4. `BuildScript` 换行：实现与测试均用 `Environment.NewLine`（CRLF），自洽，diskpart 接受 CRLF，按 brief 无需强制 `\n`，保持现状。

## 新增测试

| 测试 | 覆盖点 |
|---|---|
| `ParseOutput_DetectsAccessDenied` | 喂 `Access is denied.`（裸输出）断言判失败；另覆盖变体 `Access denied.` |
| `RunProcess_TimeoutKillsHungProcess` | 用挂起进程 `ping 127.0.0.1 -n 100` + 1.5s 超时，断言抛超时异常且耗时达超时阈值（证明走超时分支，Kill 生效）；不涉及 diskpart/clean |
| `Run_EmptyDiskList_ReturnsFailureNoDisksSelected` | 空盘列表返回 `No disks selected` 失败结果（不生成脚本、不调 diskpart） |

## 测试输出

```
C:\Program Files\dotnet\dotnet.exe build FirpeCleaner.sln -c Debug
已成功生成。 0 个警告  0 个错误

C:\Program Files\dotnet\dotnet.exe test FirpeCleaner.sln -c Debug --no-build
已通过! - 失败: 0，通过: 11，已跳过: 0，总计: 11，持续时间: 1 s - FirpeCleaner.Tests.dll (net8.0)
```

原 8 个测试全部保留通过，新增 3 个测试通过，共 11/11。

## Commit

`956f79e`：`fix(firpe-cleaner): CleanRunner 修复 review 问题（失败关键字宽松匹配/异步读+超时杀/脚本写失败/空列表）`
