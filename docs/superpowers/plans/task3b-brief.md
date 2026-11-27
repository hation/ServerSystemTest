# Task 3b brief — 修复 CleanRunner review 问题

## 背景

Task 3 review 结论 Needs fixes（2 Important + 5 Minor）。修复后进 Task 4。

## 问题清单（来自 firpe-cleaner/task3-review.md）

### Important 1：失败关键字 `access denied` 大小写不敏感匹配无法命中 "Access is denied."
- 现象：diskpart 真实输出 `Access is denied.`（中间隔 `is `），当前匹配 `access denied`
  命中不了 → 权限不足失败漏判。
- 修复：失败关键字改**宽松匹配**（如 `denied`）或增加完整短语 `access is denied`；
  同样检查其他错误关键字的真实输出形态（`no disk`/`in use` 等）。补测试：喂
  "Access is denied." 样本断言判失败。

### Important 2：RunDiskpart 超时保护失效 + 管道死锁风险
- 现象：`ReadToEnd()` 同步阻塞先于 `WaitForExit(30s)` → diskpart 挂起时超时分支不可达；
  且同步顺序读 stdout→stderr 存在管道缓冲死锁模式。
- 修复：**异步读取**（`BeginOutputReadLine`/`BeginErrorReadLine` 或
  `ReadToEndAsync`）+ `WaitForExit(timeout)` 判定 → 超时 `Kill()`；或
  `Task.WhenAll(readTasks)` 后 `WaitForExit(timeout)`。确保超时真正生效且无死锁。
  补测试：模拟挂起进程的超时杀路径（可用假进程或 mock Process——若不易测则至少
  代码结构上保证异步读+超时判定，reviewer 复核）。

### Minor（一并修）
1. WriteAllText 移入 try（写失败不留临时文件残留）→ 脚本创建失败即返回失败结果
2. diskpart 缺失时 Win32Exception 包装为明确错误信息（Failures 里）
3. 空盘列表：Run 返回 Success=false + Failures["No disks selected"]（不生成脚本）
4. BuildScript CRLF 与 brief 字面差异：测试与实现保持一致即可（不强制 \n）

## 任务

修改 `CleanRunner.cs` + 测试，修复上述全部问题，`dotnet test` 全 PASS + build 0 warning，
一次 commit：`fix(firpe-cleaner): CleanRunner 修复 review 问题（失败关键字宽松匹配/异步读+超时杀/脚本写失败/空列表）`

## 报告

写 `firpe-cleaner/task3b-report.md`：修复说明、新增测试、测试输出、commit hash。
返回：状态（DONE/BLOCKED）、commit hash、一行摘要、concerns。