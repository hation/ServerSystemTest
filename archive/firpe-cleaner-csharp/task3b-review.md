# Task 3b Review — CleanRunner review 问题修复复查

日期：2026-11-26
审查对象：commit `956f79e`（相对 `607ccfd`）；`37b09d0`/`754a70d` 仅回填报告 hash（docs-only）。
审查方式：只读静态审查 + 独立复跑 `dotnet build` / `dotnet test`。
依据：`docs/superpowers/plans/task3b-brief.md`（2 Important + 4 Minor 修复要求）。

## 一、合规核查

| 检查项 | 结果 | 说明 |
|---|---|---|
| Important 1：失败关键字宽松匹配 `denied` | ✅ | `FailureMarkers` 中 `"access denied"` 改为 `"denied"`，`"Access is denied.".Contains("denied")` 为 true，权限不足失败可判定；新增中文 `没有选定磁盘`/`已遇到错误` 补强 |
| Important 1：其他失败关键字真实形态核查 | ✅ | `There is no disk`→命中 `There is no disk selected.`；`The disk is in use`→命中 `The disk is in use.` / `in use by another process.`；`has encountered an error`→命中 `DiskPart has encountered an error: ...`；均保留 |
| Important 1：补测试 | ✅ | `ParseOutput_DetectsAccessDenied`：喂裸 `Access is denied.` 断言 `Success=false`+失败明细含 `Access is denied`；另覆盖变体 `Access denied.` |
| Important 2：异步读 | ✅ | `BeginOutputReadLine`/`BeginErrorReadLine` 事件收集 stdout/stderr，消除同步顺序读 stdout→stderr 的管道缓冲死锁 |
| Important 2：超时真生效 | ✅ | `WaitForExit(timeoutMs)` 判定 → false 时 `Kill()` + 无参 `WaitForExit()` 排空异步事件后抛超时异常；true 时补无参 `WaitForExit()`（.NET 文档要求，保证异步输出事件处理完成） |
| Important 2：超时杀路径测试真实 | ✅ | `RunProcess_TimeoutKillsHungProcess`：真挂起进程 `ping 127.0.0.1 -n 100`（实际运行约 99s）+ 1.5s 超时，断言异常消息含 `超时` 且耗时 ≥1400ms（证明走超时分支而非正常退出）；不涉及 diskpart/clean |
| Minor 1：WriteAllText 入 try | ✅ | 写失败 catch 中 `TryDelete` 清理半写残留 + 返回失败结果（`写入临时脚本失败: ...` 进 Failures） |
| Minor 2：diskpart 缺失包装 | ✅ | `Process.Start` 的 `Win32Exception` 包装为 `无法启动 diskpart（可能未安装或不在 PATH）: ...`（进 Failures 而非裸异常） |
| Minor 3：空盘列表 | ✅ | `Run` 空列表直接返回 `Success=false` + `Failures["No disks selected"]`，在 `BuildScript` 之前提前返回（不生成脚本、不调 diskpart） |
| Minor 4：换行自洽 | ✅ | 实现 `AppendLine`（CRLF）与测试 `Environment.NewLine` 断言自洽，符合 brief「不强制 \n」 |
| 测试 11/11 PASS + build 0 warning | ✅ | 已独立复跑：build「0 个警告 0 个错误」；test「失败: 0，通过: 11，已跳过: 0，总计: 11」 |
| 范围：只改 firpe-cleaner/ Core+Tests | ✅ | `git show 956f79e` 仅 3 文件：CleanRunner.cs / CleanRunnerTests.cs / task3b-report.md（报告为 brief 要求交付物）；`607ccfd..956f79e` 范围内的 `task3-report.md` 改动系 37b09d0 hash 回填（docs-only） |
| 未 push | ✅ | main 相对 origin/main ahead 37，含 956f79e/754a70d |

## 二、问题列表

### Critical
- 无。

### Important
- 无。两个 Important 均已实质修复：
  - ① `denied` 宽松匹配命中 diskpart 真实输出 `Access is denied.`，英文权限失败不再漏判（含测试锁定）；其余关键字真实形态核查无遗漏。
  - ② 异步读 + `WaitForExit(timeout)` + `Kill()` 结构上消除超时不可达与管道死锁，且超时杀路径有真实挂起进程测试实证（非 mock、非代码结构推测）。

### Minor
- 无。4 项 Minor 全部按要求修复，且修复方式无副作用：
  - 写失败清理残留并返回失败结果；Win32Exception 包装进 Failures；空列表提前返回失败；换行保持自洽。

### 观察项（不阻断，供后续参考）
- `denied` 宽松匹配属有意的误伤权衡（brief 明示），当前 diskpart 输出形态下 `denied` 仅出现在权限拒绝场景，无误伤；测试覆盖了裸输出与带前缀变体。
- 超时路径 `Kill()` 后无参 `WaitForExit()` 理论上若 Kill 静默失败会挂住，但进程由本进程启动、Kill 必然成功，非实际问题。
- `Run` 对外行为由「抛异常」变为「返回失败结果（信息进 Failures）」，属 brief 要求的有意变更，对 GUI 调用方更友好。

## 三、复跑证据（独立复跑）

```
dotnet build FirpeCleaner.sln -c Debug
已成功生成。 0 个警告  0 个错误

dotnet test FirpeCleaner.sln -c Debug --no-build
已通过! - 失败: 0，通过: 11，已跳过: 0，总计: 11，持续时间: 1 s - FirpeCleaner.Tests.dll (net8.0)
```

## 四、结论

**Approved**

`956f79e` 完整修复 task3-review 的 2 Important + 4 Minor：失败关键字宽松匹配命中真实输出（含测试）、异步读+超时杀消除死锁且超时路径有真实挂起进程测试实证、脚本写失败清理残留/diskpart 缺失包装/空盘列表失败语义全部落地；独立复跑 build 0 warning + 11/11 PASS；范围仅 firpe-cleaner/ Core+Tests（+报告文档），未 push。可进入 Task 4。
