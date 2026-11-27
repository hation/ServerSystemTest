# Task 4 审查报告 — GUI 主窗口（commit bda9558，base 956f79e）

- 审查对象：`firpe-cleaner/src/FirpeCleaner/MainWindow.xaml(.cs)`、`ConfirmDialog.xaml(.cs)`、`App.xaml.cs`（commit `bda9558`，相对 `956f79e`）
- 审查方式：只读。逐行读源码 + Core（DiskEnumerator.cs/CleanRunner.cs/DiskInfo.cs）+ git 状态核对 + `dotnet build` 复跑 + 本机 WMI schema/C# 运行时探针
- 结论：**Approved**（Core 遗留 Bug 已核实属实，Important 待下个任务修，不阻塞本任务合入）

## 1. Spec 合规 ✅

| 要求 | 结果 |
|------|------|
| 六列盘列表：勾选/盘号/类型/总容量/剩余容量/状态 | ✅ MainWindow.xaml 六列（Pick \| Disk \| Bus \| Size (GB) \| Free (GB) \| Status） |
| 勾选默认全选（排除盘除外） | ✅ `DiskRow.IsChecked = !IsExcluded`，排除盘不勾选 |
| 排除盘显示但勾选禁用 + 状态列原因 | ✅ 模板列 CheckBox `IsEnabled={Binding CanClean}`；状态列 DataTrigger 标红；排除原因经 `TranslateExcludeReason` 映射为 ASCII |
| 空状态 + 清理按钮禁用 | ✅ `cleanable==0` → EmptyState 显示 + `CleanBtn.IsEnabled=false`（含全排除场景） |
| 清理 → 确认弹窗列出选中盘 → SetRunning 锁定 → CleanRunner.Run → 成功 Growl/失败列出 | ✅ 全链路：`Clean_Click` 收集 `IsChecked && CanClean` → ConfirmDialog 列出盘号/型号/容量 → 确认后 `SetRunning(true)` → `Task.Run(new CleanRunner().Run(numbers))` → 成功 `Growl.Success("Disks cleaned. Ready to reinstall.")` / 失败 MessageBox 逐条 + Growl |
| 全 ASCII 用户可见文本 | ✅ grep 核实：XAML 全部 CJK 仅存在于注释；`Text="…"` 属性零中文；.cs 字符串常量全 ASCII（唯一 CJK 字符串为 `TranslateExcludeReason` 的 Core 中文常量匹配键，不展示）；App.xaml.cs 未捕获异常 Growl 已改 ASCII |

## 2. 代码质量 ✅（含 Minor 观察项）

- 异步加载：`Task.Run(DiskEnumerator.Enumerate)` → UI 线程绑定 `ObservableCollection<DiskRow>`，await 续延均在 UI 线程 ✅
- 确认弹窗收集选中盘正确：排除盘复选框禁用 + 默认不勾选 + `Clean_Click` 再过滤 `CanClean`（双保险）✅
- 运行态锁定：SetRunning 禁用清理按钮/盘列表/主题切换；`Window_Closing` 运行中拦截（YesNo 确认）✅
- 异常处理：枚举失败 → Status/日志/Growl 显示原因；清理失败 → 状态 Failed + 逐条 MessageBox + Growl ✅
- Core 接口用法正确：`DiskEnumerator.Enumerate()` → `IReadOnlyList<DiskInfo>`；`CleanRunner().Run(numbers)` → `CleanResult{Success, Failures, CleanedCount}`，成功判定 `result.Success` ✅
- 构建：复跑 `dotnet build FirpeCleaner.sln -c Debug` → **0 警告 0 错误** ✅
- 范围：`git show --stat bda9558` 仅改 FirpeCleaner exe 项目 5 文件（App.xaml.cs/ConfirmDialog.xaml(.cs)/MainWindow.xaml(.cs)），Core 零改动；`main [ahead 39]` 未 push ✅

## 3. Core 遗留 Bug 核实结论（subagent 报告属实 ✅）

**`DiskEnumerator.EnumerateByWmi()` 读 `Win32_LogicalDisk.BootPartition`（DiskEnumerator.cs L169-171）→ 主路径必抛。**

三重实证（本机复验）：
1. **Schema 层**：`Get-CimClass Win32_LogicalDisk` 列出全部 43 个属性，**无 `BootPartition`**（该属性属 `Win32_DiskPartition`）。
2. **运行时层**：C# 直接索引器访问探针 `new ManagementObject("Win32_LogicalDisk.DeviceID='C:'")["BootPartition"]` → 抛 `System.Management.ManagementException / Not found`（WBEM_E_NOT_FOUND）。⚠️ 注意 PowerShell 适配器访问缺失属性返回 null 不抛（初测易误判），Core 走的是直接 C# 索引器，必抛。
3. **代码路径**：异常在 L171 第一次迭代即抛出 → 穿透 `EnumerateByWmi()` → 被 `Enumerate()` L33 catch 捕获 → **任何标准 Windows/WinPE 上 WMI 主路径 100% 回退 diskpart**，`Win32_DiskDrive` 查询（型号/序列号/介质/剩余容量归并）永不执行。

**严重性评估：Important（待下个任务修，非 Critical）**
- 功能影响：FirPE（管理员）下 diskpart 回退可用 → 列盘/清理仍工作；系统盘判定经 `detail disk` 的 "Boot Disk" 行（正则已覆盖英文/中文）**仍有效**；但 **Model/SN/Media/FreeGB 全丢**，剩余容量恒显示 "-"，`IsHdd` 失效。
- 环境影响：非管理员 Windows（如本机冒烟环境）diskpart 提权失败 → 枚举整体失败 → GUI "Disk scan failed."。
- 修复建议（与 subagent 一致）：系统盘判定改为遍历 `Win32_DiskPartition` 读 `BootPartition=True` 的 `DiskIndex`。

## 4. 问题列表

### Critical
- 无（GUI 自身无 Critical；Core Bug 为 Task 2 遗留，归 Important 待下个任务修）

### Important
1. **[Core 遗留] EnumerateByWmi 读 LogicalDisk.BootPartition 必抛**（见 §3）→ WMI 主路径永远失效。下个任务修（改用 Win32_DiskPartition.BootPartition），本任务不阻塞。

### Minor
1. **错误文本可能非 ASCII**：`ex.Message`（枚举失败）与 `result.Failures`（清理失败，diskpart/OS 中文原文）会原样进 Growl/日志/MessageBox，PE 无中文字体显示为方块。Core/系统文本不在 GUI 控制范围（报告已自述）；建议下个任务 Core 错误消息 ASCII 化或 GUI 侧兜底。
2. **全排除时双重提示**：EmptyState 横幅 + `Growl.Warning` 同时触发；换肤重建窗口会再触发一次 Growl（轻微噪音，非错误）。
3. **事件接线不一致（观察项）**：`Loaded` 走构造函数订阅（报告称 hc:Window 下 XAML `Loaded=` 不可靠），`Closing` 仍走 XAML 属性。与 disk-tests 参考实现完全一致（XAML Closing + ctor Loaded），无法在本环境运行时验证 Closing 是否受同样影响；如担心可改构造函数订阅，非阻塞。
4. **ConfirmDialog Owner 取 `Application.Current.MainWindow`**：主题切换重建窗口瞬间极端时序下可能指向旧窗口，模态弹窗场景下实际不可达，无害。

## 5. 结论

**Approved**。Spec 六项全部合规、0 warning/0 error、Core 零改动未 push、冒烟证据（真实列盘/排除禁用/勾选交互/确认弹窗/假 CleanRunner 成功链路/失败路径）与代码一致。Core WMI `BootPartition` 遗留 Bug 经 schema + C# 运行时双重实证确认真实存在，列为 Important 待下个任务修复。
