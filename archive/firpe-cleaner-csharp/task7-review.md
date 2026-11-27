# Task 7 Review — 系统盘可清 + UI 布局调整（commit 6839fb4，相对 46a4cdd）

日期：2026-11-26
审查方式：只读代码审查 + 复跑 build/test + git 状态核验

## 合规检查

| # | 要求 | 结果 | 证据 |
|---|------|------|------|
| 1 | 系统盘排除已去掉（Filter 无 IsBoot 排除分支），USB/Removable/CD/DVD/<1GB 保留 | ✅ | `DiskEnumerator.Filter`（DiskEnumerator.cs:44-71）仅保留 BusIsUsb / MediaIsRemovableOrOptical / SizeUnknown / SizeGB<1 四类排除，无 `IsBoot` 分支；`"系统盘（启动盘）"` 排除原因已删除 |
| 2 | IsBoot 保留为展示字段（public），GUI 状态列显示 "Cleanable (system/boot)" | ✅ | DiskInfo.cs:43 `public bool IsBoot`（注释明确"仅用于 UI 状态列展示，不再参与排除"）；MainWindow.xaml.cs:35-37 `Info.IsBoot ? "Cleanable (system/boot)" : "Cleanable"`。IsBoot 改 public 必要性成立：GUI 程序集读取该字段而 IVT 仅授予 Tests |
| 3 | UI 布局：Grid 行比例（列表占主体 *）、日志区收窄（MaxHeight）、DataGrid 滚动 | ✅ | MainWindow.xaml:12-17 行定义 `* / Auto / Auto / Auto`（Row0 列表占 *，Row3 日志由 2* 改 Auto）；LogBox `MaxHeight="110"`（MainWindow.xaml:149）；DataGrid `VerticalScrollBarVisibility="Auto"` + `CanUserAddRows="False"` + `MinHeight="140"`（MainWindow.xaml:35-41） |
| 4 | 测试翻转正确（Filter_KeepsBootDiskByIsBoot） | ✅ | DiskEnumeratorTests.cs:39-55，`IsBoot=true` 盘断言 `IsExcluded=false`、`ExcludeReason=""`；USB/CD/<1GB/未知容量/diskpart 解析/WMI 判定等其余 9 用例不变 |
| 5 | dotnet build 0 warning 0 error + test 15/15 PASS（已复跑） | ✅ | 复跑 `dotnet build FirpeCleaner.sln -c Debug`：0 警告 0 错误；`dotnet test --no-build`：已通过 15/15（失败 0） |
| 6 | 只改 firpe-cleaner/，未 push | ✅ | `git diff --stat 46a4cdd..6839fb4` 仅 firpe-cleaner/ 下 7 文件；`git status -sb`：main ahead origin/main 46（6839fb4 及后续 docs 回填 c23fdaa 均未推送） |

附：文案残留检查——空状态、日志、Growl 文案已统一为 "USB / CD / removable disks are excluded automatically."，无过时 "system / boot disks" 残留；状态列翻译分支已删除 "Excluded: system/boot disk"。

## 问题列表

- **Critical**：无
- **Important**：无
- **Minor**：
  1. FirpeCleaner.Core.csproj:16 注释「测试程序集可访问 internal 成员（如 DiskInfo.IsBoot）」举例过时——IsBoot 已改 public；IVT 因 CleanRunner 的 internal `BuildScript/ParseOutput/RunProcess`（CleanRunner.cs:106/118/175）仍属必要，仅注释举例建议改为 CleanRunner 或删除 IsBoot 字样。纯注释，不影响功能与构建。

## 结论

**Approved** — 六项合规要求全部通过，复跑 build（0w/0e）与 test（15/15 PASS）一致；无 Critical/Important 问题，仅 1 条 Minor 注释过时项（可留待后续顺手修正，不阻塞合入）。
