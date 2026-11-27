# Task 4 brief — GUI 主窗口（列盘/默认全选/确认弹窗/清理/结果）

## 背景

firpe-cleaner GUI 主窗口：列盘（勾选/盘号/类型/总容量/剩余容量/状态）→ 默认全选（排除已标注）→ 清理按钮 → 确认弹窗列出选中盘 → diskpart 清理 → 结果提示。参考 disk-tests 的 gui-template（HandyControl/WPF/Code-behind）。

## 需求来源

- Spec：`docs/superpowers/specs/2026-11-26-firpe-cleaner-gui-design.md` §3/§5/§6
- Plan：`docs/superpowers/plans/2026-11-26-firpe-cleaner-gui.md` Task 4

## 任务（精确，基于 HEAD=956f79e）

### 1. `firpe-cleaner/src/FirpeCleaner/MainWindow.xaml(.cs)`（重写业务）
- 布局：顶部盘列表区（Border 包 DataGrid + 空状态提示条）→ 中部操作区（清理按钮）
  → 底部状态栏（状态文本 + 日志区）
- DataGrid 列：勾选 CheckBox | 盘号(PhysicalDriveN) | 类型(Bus) | 总容量(SizeGB)
  | 剩余容量(FreeGB 或 "-") | 状态（可清理/排除原因）
- 排除盘：显示但勾选禁用（IsEnabled=false 或 IsExcluded 时 checkbox 不可勾选），
  状态列标 ExcludeReason
- 加载：OnLoaded → Task.Run(DiskEnumerator.Enumerate) → 绑定 ObservableCollection<DiskRow>
  → 默认勾选全部可清理盘；无盘/全排除 → 空状态提示 + 清理按钮禁用
- 清理按钮：收集选中盘（勾选且非排除）→ 确认弹窗列出选中盘
  （盘号/型号/容量）→ 确认 → SetRunning 锁定 + Task.Run(CleanRunner.Run)
  → 结果：成功 Growl「Disks cleaned. Ready to reinstall.」/ 失败列出
- 全部用户可见文本**纯 ASCII**（PE 无中文字体）
- 参考 disk-tests MainWindow.xaml(.cs)（~783 行单文件）的 FitToScreen/主题切换/
  SetRunning/进度模式

### 2. `ConfirmDialog`（简化）
- 模板 ConfirmDialog 原是强确认（输入文本）——按用户需求改为**普通确认弹窗**：
  列出选中盘名称/盘号/容量 + 确定/取消按钮（可用 MessageBox.Show 替代，或保留
  ConfirmDialog 但去掉输入框改为纯列表+按钮）

### 3. 验证
- `dotnet build` 0 warning 0 error
- 本机跑 exe 冒烟：列盘正常（真实盘）、勾选正常、确认弹窗正常、清理按钮
  （**本机不真 clean**——点击确认前可中断/或用假 CleanRunner）
- 如 GUI 冒烟难以完全自动验证，报告说明人工冒烟步骤

### 4. Commit
`feat(firpe-cleaner): GUI 主窗口（列盘/默认全选/确认弹窗/清理/结果提示）`

## 环境

- dotnet 8 SDK；只改 firpe-cleaner/ 的 FirpeCleaner（exe 项目）
- Core 已提供：DiskEnumerator.Enumerate() → IReadOnlyList<DiskInfo>；CleanRunner.Run() → CleanResult

## 禁止

- 不改 Core；不真 clean 本机盘（冒烟只列盘+弹窗，确认前不执行清理）
- 不 push

## 报告

写 `firpe-cleaner/task4-report.md`：UI 实现说明、本机冒烟结果（截图/描述）、commit hash。
返回：状态（DONE/BLOCKED）、commit hash、一行摘要、concerns。