# Task 3 Review — Core diskpart 清理执行器（CleanRunner.cs + CleanRunnerTests.cs）

日期：2026-11-26
审查对象：commit `607ccfd`（相对 `fb3e44a`）；后续 `37b09d0` 仅回填报告中的 commit hash（docs-only，不影响本审查）。
审查方式：只读静态审查 + 独立复跑 `dotnet build` / `dotnet test`。

## 一、合规核查

| 检查项 | 结果 | 说明 |
|---|---|---|
| 仅 `clean`（无 `clean all`） | ✅ | `BuildScript` 每盘仅 `select disk N` + `clean`；测试 `DoesNotContain("clean all")` 兜底 |
| 每盘 `select disk N` + `clean` | ✅ | `foreach` 逐盘生成两行 |
| 脚本写入 `%TEMP%` | ✅ | `Path.GetTempPath()` + `firpe-clean-{guid8}.txt` |
| Process 捕获 stdout/stderr | ✅ | `UseShellExecute=false` + 双 Redirect；stderr 并入输出供解析 |
| 成功/失败解析 | ✅（含 1 个 Important 缺陷，见下） | 成功关键字 + 8 个中英失败关键字 |
| finally 删除临时脚本 | ✅ | try/finally `File.Delete`（删除失败吞掉不影响结果） |
| `[SupportedOSPlatform("windows")]` | ✅ | Core 类与测试类均标注 |
| 测试不调用 `Run`（防真 clean） | ✅ | 仅测 internal `BuildScript`/`ParseOutput` |
| 范围：只改 firpe-cleaner/ Core+Tests | ✅ | `git diff fb3e44a 607ccfd` 仅 3 文件（CleanRunner.cs / CleanRunnerTests.cs / task3-report.md，报告为 brief 要求交付物） |
| 未 push | ✅ | main 相对 origin/main ahead 35，含 607ccfd/37b09d0 |
| build 0 warning + test 8/8 PASS | ✅ | 已独立复跑：build「0 个警告 0 个错误」；test「通过: 8，失败: 0」 |

## 二、问题列表

### Critical
- 无。

### Important

1. **失败关键字 `access denied` 无法命中 diskpart 实际输出 `Access is denied.`（失败漏判）**
   - 位置：`CleanRunner.cs` FailureMarkers（`"access denied"`）。
   - 事实：大小写不敏感匹配下，`"Access is denied.".Contains("access denied")` 为 **false**（中间隔了 `is `）。而 diskpart 权限不足时的真实英文输出正是 `Access is denied.`（或带前缀的 `DiskPart has encountered an error: Access is denied.`，后者可被 `has encountered an error` 命中，但裸 `Access is denied.` 会漏判）。
   - 影响：权限不足场景下该盘失败不被计入 `Failures`；混合场景（其他盘成功）下 `CleanedCount` 虚高，违反 brief 点名的「access denied 判定失败」与「失败不漏判」要求。中文场景有 `拒绝访问` 兜底，英文场景无。
   - 建议：marker 改为 `access is denied`（或追加 `denied`）。

2. **超时保护无效：`ReadToEnd()` 同步阻塞先于 `WaitForExit(30s)`**
   - 位置：`CleanRunner.cs` `RunDiskpart`。
   - 事实：先 `p.StandardOutput.ReadToEnd()`、再 `p.StandardError.ReadToEnd()`（均阻塞至管道 EOF），之后才 `WaitForExit(30_000)`。若 diskpart 挂起不退出，stdout 管道不关闭，`ReadToEnd()` 永不返回，30s 超时分支（`Kill` + throw）实际不可达；且顺序同步读 stdout→stderr 是经典管道缓冲死锁模式（子进程 stderr 输出超 4KB 时阻塞写，父进程仍阻塞读 stdout）。
   - 影响：超时保护形同虚设；diskpart 输出量小故死锁概率低，但超时失效是确定的结构性缺陷，且该路径本机无法端到端实测（报告已声明）。
   - 建议：改用 `WaitForExitAsync`（带 CancellationToken/超时）+ 异步读（`ReadToEndAsync`），或先超时等待再读、stderr 用后台任务读。

### Minor

3. **脚本写失败时可能残留临时文件**：`File.WriteAllText` 在 try 之外，写失败（磁盘满/权限）时异常传播且不清理可能半写的临时脚本。概率低，可接受；如需可把写文件移入 try 或在 catch 中删除。
4. **中文系统成功误判（实现报告已如实披露）**：成功判定仅认英文 `DiskPart successfully`；中文系统输出 `DiskPart 已成功…` 会得到 `Success=false` 且 `Failures` 空、`CleanedCount=0`（保守误判，无破坏性）。brief 仅要求英文关键字，属已知限制；若目标环境含中文系统，建议后续补中文成功关键字。
5. **`BuildScript` 文本为 CRLF（`Environment.NewLine`），与 brief 字面 `\n` 不同**：测试用 `Environment.NewLine` 断言与实现自洽，diskpart 接受 CRLF，无实际影响。
6. **diskpart 不在 PATH 时 `Process.Start` 抛 `Win32Exception`**：启动失败有兜底（`?? throw InvalidOperationException`），但 Win32Exception 未包装为友好消息，可接受。
7. **空盘列表语义边界**：空输入 → `Success=false` 且 `Failures` 空（无成功也无失败）；调用方应避免空列表，非缺陷。

## 三、复跑证据

```
dotnet build FirpeCleaner.sln -c Debug
已成功生成。 0 个警告  0 个错误

dotnet test FirpeCleaner.sln -c Debug --no-build
已通过! - 失败: 0，通过: 8，已跳过: 0，总计: 8，持续时间: 12 ms - FirpeCleaner.Tests.dll (net8.0)
```

## 四、结论

**Needs fixes**

Spec 主体合规、测试质量好（精确断言 + 三态解析 + 不调 Run）、范围/提交/push 全部达标；但存在两个 Important 实质缺陷：① 失败关键字 `access denied` 匹配不到真实输出 `Access is denied.`（失败漏判，违反 brief 点名关键字）；② 同步 `ReadToEnd` 先于 `WaitForExit` 导致超时保护失效（且存在管道死锁模式）。建议修复后合入。
