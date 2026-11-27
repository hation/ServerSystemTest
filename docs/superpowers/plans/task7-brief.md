# Task 7 brief — 系统盘可清 + UI 布局调整（列表放大+滚动+日志缩小）

## 背景

用户反馈两个问题：
1. **系统盘也要列出可清除**——用户场景是 FirPE（WinPE）里用，系统盘（PE 启动盘=U 盘被 USB 规则排除；SAS/SATA 内置盘即使被 Windows 判定"系统盘"也需要清）。当前实现把系统盘排除（IsBoot→ExcludeReason="System disk"）——**去掉该系统盘排除逻辑**，系统盘像普通盘一样列出可勾选。
2. **UI 布局**：硬盘列表区太小——放大（占主窗口主体）、支持滑动（ScrollViewer/DataGrid 内滚动）；日志区缩小（不是主要信息）。

注意：U 盘（USB）与 CD 盘仍排除（FirPE 启动 U 盘不能清，否则启动盘没了）；仅去掉**系统盘**排除。

## 任务（精确，基于 HEAD=46a4cdd）

### 1. `firpe-cleaner/src/FirpeCleaner.Core/DiskEnumerator.cs`：去掉系统盘排除
- `Filter` 中删除 `IsBoot` 排除逻辑（不再把系统盘标 Excluded）
- 保留：USB 排除、MediaType Removable/CD/DVD 排除、Size<1GB 排除
- `DiskInfo.IsBoot` 字段保留（可展示为状态列信息但不排除），`ExcludeReason` 不再有 "System disk"

### 2. `firpe-cleaner/src/FirpeCleaner/MainWindow.xaml`：布局调整
- 硬盘列表区放大：DataGrid 占主窗口主体（行高/列宽合理，Grid 行分配大头给列表）
- 支持滑动：DataGrid 本身支持滚动（CanUserAddRows=false + 默认 ScrollViewer）；确认 MaxHeight/容器高度足够；若当前被日志区挤压则调整 Grid 行比例（列表 *、日志 Auto/小高度）
- 日志区缩小：状态栏保留（进度/状态），日志区收窄（或最小化行高、仅保留少量行）

### 3. 验证
- `dotnet build` 0 warning 0 error
- 本机跑 exe 冒烟：列盘（系统盘现在也列出可勾选）、滚动正常、布局合理（截图确认列表占主体）

### 4. Commit
`feat(firpe-cleaner): 系统盘可清除（FirPE 场景去除系统盘排除）+ UI 布局（列表放大+滚动+日志缩小）`

## 环境

- dotnet 8 SDK；只改 firpe-cleaner/（Core 的 Filter + GUI 的 XAML）
- 本机 1 块系统盘：冒烟验证系统盘现在列出可勾选

## 禁止

- 保留 USB/CD/Size<1GB 排除（不误清启动 U 盘）
- 不真 clean 本机盘；不 push

## 报告

写 `firpe-cleaner/task7-report.md`：改动说明、本机冒烟（截图描述：系统盘列出+列表大+滚动）、commit hash。
返回：状态（DONE/BLOCKED）、commit hash、一行摘要、concerns。