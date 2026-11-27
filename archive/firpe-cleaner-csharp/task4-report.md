# Task 4 报告 — GUI 主窗口（列盘/默认全选/确认弹窗/清理/结果提示）

- 状态：DONE（含 1 个 Core 阻塞性发现，见"发现"节）
- 实现 commit：`bda9558`（`feat(firpe-cleaner): GUI 主窗口（列盘/默认全选/确认弹窗/清理/结果提示）`）
- 报告 commit：本文件回填于后续 docs commit

## 1. UI 实现说明

### MainWindow.xaml(.cs)（重写业务）
- **布局**（三行 + 日志区，符合 brief"顶部盘列表→中部操作区→底部状态栏+日志区"）：
  1. 盘列表区：Border 包 DataGrid + 空状态提示条
  2. 操作区：清理按钮 + 说明文字
  3. 状态栏：Status 文本 + 主题切换按钮
  4. 日志区：只读 TextBox（Consolas，可滚动，200k 上限截断）
- **DataGrid 六列**：勾选（模板 CheckBox）| 盘号 PhysicalDriveN | 类型 Bus | 总容量 Size(GB) | 剩余容量 Free(GB)（拿不到显示 "-"）| 状态
- **排除盘**：`IsExcluded` 时 CheckBox `IsEnabled=false`（模板列绑定 `CanClean`）且默认不勾选；状态列显示排除原因（ASCII 映射，见下）
- **加载**：构造函数订阅 `Loaded += OnLoaded`（与 disk-tests 一致——注意：XAML 根元素 `Loaded=` 属性事件在 hc:Window 下不可靠，本任务实际踩坑，见"发现"节）→ `Task.Run(DiskEnumerator.Enumerate)` → 绑定 `ObservableCollection<DiskRow>` → 默认勾选全部可清理盘；无盘/全排除 → 空状态提示 + 清理按钮禁用
- **清理流程**：按钮 → 收集勾选且非排除盘 → ConfirmDialog 普通确认（列出盘号/型号/容量）→ 确认后 `SetRunning(true)`（禁用清理按钮/盘列表/主题切换）→ `Task.Run(CleanRunner.Run)` → 成功 Growl `Disks cleaned. Ready to reinstall.` / 失败 MessageBox 逐条列出失败 + Growl
- **窗口关闭拦截**：清理运行中关闭 → 确认弹窗（YesNo）
- **FitToScreen/GetDpiForWindow/主题切换/AppendLog**：照搬 disk-tests 模式
- **全部用户可见文本纯 ASCII**：窗口标题、按钮、状态、日志、Growl、空状态、确认弹窗均为英文（PE 无中文字体）

### 排除原因 ASCII 映射（DiskRow.Status）
Core 的 `ExcludeReason` 是中文常量（不改 Core），GUI 映射为英文：
`系统盘（启动盘）`→`Excluded: system/boot disk`；`USB 移动盘`→`Excluded: USB removable`；`可移动/CD/DVD 介质`→`Excluded: removable / CD / DVD`；`容量未知`→`Excluded: size unknown`；`容量小于 1GB`→`Excluded: size < 1GB`；未知原因兜底 `Excluded`（保证纯 ASCII）

### ConfirmDialog（简化）
- 去掉输入框，改为：警告提示 + 选中盘清单（ItemsControl，超高可滚动）+ Cancel/Clean 按钮
- `ConfirmDialog.Show(prompt, IReadOnlyList<string> lines) → bool`
- 全部文本 ASCII

### 其他
- `App.xaml.cs`：未捕获异常 Growl 文案改 ASCII（`An unhandled error occurred and was logged. Restart the app if the UI becomes unstable.`）

## 2. 构建

`dotnet build FirpeCleaner.sln -c Debug`：**0 warning / 0 error**

## 3. 本机冒烟结果（2026-11-26，Windows 桌面会话，UIA 自动化驱动）

本机环境：1 块物理盘 `PhysicalDrive0`（SCSI / 477GB / C: 系统盘），非管理员会话（diskpart 需提权，Debug 无管理员 manifest）。

**冒烟方法**：启动 exe → UIAutomation 驱动（列盘/勾选/点清理按钮/读确认弹窗/点取消；**全程未执行真实清理**）。

### 冒烟 A：真实列盘 + 排除展示 + 空状态（临时本地 Core 补丁，见"发现"节）
- 窗口正常出现，标题 `FirPE Disk Cleaner`
- DataGrid 1 行：`PhysicalDrive0 | SCSI | 477 | 234 | Excluded: system/boot disk`
  - 勾选列：`checkboxEnabled=False`、`ToggleState=Off`（排除盘禁用且不勾选）✓
  - 状态列正确显示 ASCII 排除原因 ✓
- 状态栏：`No cleanable disk (all excluded).`；日志：`Found 1 disk(s), 0 cleanable.`/`No cleanable disk found. ...` ✓
- 清理按钮禁用 ✓（全排除 → 空状态 + 禁用）

### 冒烟 B1：勾选 + 确认弹窗 + 取消（临时 GUI 补丁强制本机单盘可清理，验证交互流程）
- 勾选列默认 `ToggleState=On`（默认全选）+ 可勾选 ✓
- 勾选交互：On → Toggle → Off → Toggle → 恢复 On ✓
- 清理按钮可用 → 点击 → 确认弹窗 `Confirm Clean` 出现：
  - 警告文本：`WARNING: The following disks will be cleaned. All data will be lost and cannot be recovered!` ✓
  - 选中盘列表：`PhysicalDrive0 (YMTC YMSS2ED06B66MC, 477 GB)`（盘号+型号+容量）✓
  - `This operation cannot be undone.` + `Cancel`/`Clean` 按钮 ✓
- 点 Cancel → 弹窗关闭，主窗口日志追加 `Clean cancelled by user.`（**未执行任何清理**）✓

### 冒烟 B2：清理成功结果提示（`FIRPE_FAKE_CLEAN=1` 临时假 CleanRunner，不真 clean）
- 确认弹窗点 Clean → 状态 `Done`；日志 `Clean start: PhysicalDrive0` / `Clean finished: 1 disk(s) cleaned.`；清理按钮恢复可用（SetRunning(false)）✓
- Growl `Disks cleaned. Ready to reinstall.`：与状态/日志同属成功分支，代码字符串已核对；本会话 UIA 无法捕获 HC toast 文本（与 owned-window UIA 不可见同属会话限制），建议真机人工确认

### 主题切换
未自动化验证（换肤重建窗口路径与 disk-tests 完全一致），建议人工冒烟。

### 人工冒烟步骤（真机 / FirPE）
1. 双击 exe → 列表列出真实盘，默认全选（USB/CD/系统盘显示但勾选禁用、状态列标排除原因）
2. 取消勾选某盘 → 点 `Clean Selected Disks` → 确认弹窗列出选中盘（盘号/型号/容量）→ 点 Cancel 确认可中止
3. 点 Clean 确认 → 状态 `Done` + Growl `Disks cleaned. Ready to reinstall.` → DiskGenius 核实盘为未初始化
4. 切换主题按钮（浅/深色即时生效）

## 4. 发现（重要，需 Core 修复）

**Core WMI 枚举 Bug（Task 2 遗留，本次冒烟暴露）**：
`DiskEnumerator.EnumerateByWmi()` 对 `Win32_LogicalDisk` 读取 `BootPartition` 属性（`DiskEnumerator.cs` ~L169），
但该属性**属于 `Win32_DiskPartition`，`Win32_LogicalDisk` 类无此属性**（已用 `Get-CimClass` 核实本机 schema；
CIM 标准 schema 亦如此）。访问抛 `ManagementException: 找不到 (WBEM_E_NOT_FOUND)` → `Enumerate()` 的 try/catch
回退 diskpart；本机（非管理员）diskpart 启动失败（"请求的操作需要提升"）→ 最终 GUI 显示 `Disk scan failed.`。

影响：
- **任何标准 Windows/WinPE 上 WMI 主路径都会抛异常**（不是本机特例），实际全部走 diskpart 回退；
  在 FirPE（管理员运行）里 diskpart 可用，功能仍可工作，但 WMI 剩余容量/型号/序列号字段会丢失；
- 本机冒烟"真实列盘"因此受阻（diskpart 需提权）。

临时冒烟补丁（已回退，未提交）：把系统盘判定改为遍历 `Win32_DiskPartition` 读 `BootPartition`（正确语义），
冒烟 A/B 均在此补丁下完成。**Core 修复建议（下个任务）**：系统盘判定改为
`foreach p in Win32_DiskPartition: if BootPartition==True → DiskIndex`（即本次临时补丁逻辑）。

其他 concerns：
- CleanRunner 失败明细/diskpart 原始输出可能含中文（Core/系统语言），GUI 原样展示，不保证 ASCII（Core 文本不在 GUI 控制范围）。
- 排除原因未知值兜底显示 `Excluded`（不显示原文，保证 ASCII；Core 新增排除原因时需同步扩展映射）。
- 本机唯一盘为系统盘，真实环境下"默认全选可清理盘"的完整形态未能在本机复现（无第二块数据盘），冒烟 B 用临时强制可清理补丁验证了交互流程。

## 5. Commit

- `bda9558` `feat(firpe-cleaner): GUI 主窗口（列盘/默认全选/确认弹窗/清理/结果提示）`
  - 文件：`src/FirpeCleaner/MainWindow.xaml(.cs)`、`src/FirpeCleaner/ConfirmDialog.xaml(.cs)`、`src/FirpeCleaner/App.xaml.cs`
  - 未改 Core；未 push
