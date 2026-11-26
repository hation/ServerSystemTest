# Task 7 Report — 系统盘可清 + UI 布局调整（列表放大+滚动+日志缩小）

日期：2026-11-26
基准：HEAD=46a4cdd

## 改动说明

### 1. Core：去掉系统盘排除（`src/FirpeCleaner.Core/`）

- **`DiskEnumerator.cs`**：`Filter` 删除 `IsBoot` 排除分支（不再标 `Excluded`/`ExcludeReason="系统盘（启动盘）"`）。
  保留：USB 总线排除、Removable/CD/DVD 介质排除、容量未知排除、容量 <1GB 排除（不误清 FirPE 启动 U 盘）。
  `EnumerateByWmi` 的 BootPartition→DiskIndex 判定与 diskpart 回退的 "Boot Disk" 标记解析**保留**，仅用于写 `DiskInfo.IsBoot` 供 UI 展示。
- **`DiskInfo.cs`**：`IsBoot` 由 `internal` 改为 `public`（GUI 程序集读取状态列展示需要；`InternalsVisibleTo` 仅授予 Tests，不改 public 则 GUI 编译不过），注释更新为"仅用于 UI 状态列展示，不再参与排除"。
- **`FirpeCleaner.Core.csproj`**：InternalsVisibleTo 注释同步（不再用于"启动盘过滤用例"）。

### 2. GUI：布局调整（`src/FirpeCleaner/MainWindow.xaml` + `.xaml.cs`）

- **`MainWindow.xaml`**：
  - Grid 行定义由 `* / Auto / Auto / 2*`（日志区占大头）改为 `* / Auto / Auto / Auto`——盘列表区（Row0）占主体，日志区（Row3）收窄为内容高度。
  - 日志 `TextBox` 加 `MaxHeight="110"`（实际渲染约 74px，仅保留少量行）。
  - 盘列表 DataGrid 保持 `VerticalScrollBarVisibility="Auto"` + `CanUserAddRows=False`（DataGrid 内置 ScrollViewer，多盘时行内滚动）。
  - 空状态文案 "USB / CD / system / boot disks are excluded automatically." → "USB / CD / removable disks are excluded automatically."。
- **`MainWindow.xaml.cs`**：
  - `DiskRow.Status`：未排除盘若 `IsBoot` 显示 `Cleanable (system/boot)`（系统盘可见标注，纯 ASCII），否则 `Cleanable`；删除已不存在的 "系统盘（启动盘）" 排除原因翻译分支。
  - 日志/Growl 文案同步去掉 "system / boot disks"。

### 3. Tests（`tests/FirpeCleaner.Tests/DiskEnumeratorTests.cs`）

- `Filter_ExcludesBootDiskByIsBoot` 翻转为 `Filter_KeepsBootDiskByIsBoot`：`IsBoot=true` 的盘**不再排除**（`IsExcluded=false`、`ExcludeReason=""`），与 FirPE 场景需求一致。
- 其余用例（USB/CD/<1GB/未知容量/diskpart 解析/FindBootDiskIndex）不变，均未断言系统盘排除。

## 验证结果

- `dotnet build FirpeCleaner.sln -c Debug`：**0 warning / 0 error**。
- `dotnet test FirpeCleaner.sln -c Debug --no-build`：**15/15 PASS**（失败 0）。

## 本机冒烟（FirpeCleaner.exe，Debug win-x64）

通过 UI Automation 实测（截图存 `firpe-cleaner/task7-smoke.png`，1280×780 窗口）：

- **系统盘列出且可勾选**：DataGrid 共 1 行 `PhysicalDrive0`（Bus=SCSI，477 GB——本机唯一系统盘），CheckBox **ToggleState=On 且 IsEnabled=True**，状态列显示 **"Cleanable (system/boot)"**。旧行为此盘被排除（`Excluded: system/boot disk`、复选框禁用），现系统盘可勾选可清。U 盘/CD 排除规则未误伤（本机无 USB 盘；规则保留）。
- **列表放大占主体**：像素扫描确认列表区 y≈40–360（约 320px，占窗口高 780 的 41%，为最大单区）；旧布局列表区仅约 1/5 且被日志区（2*）反超。
- **滚动正常**：DataGrid 带内置 ScrollViewer + `VerticalScrollBarVisibility=Auto`，UIA ScrollPattern 存在；当前仅 1 盘无可滚动内容（VerticalScrollable=False 属预期），多盘时自动出现垂直滚动条。
- **日志缩小**：日志区收窄为底部小条，TextBox 实际高 74px（`MaxHeight=110` 生效，仅少量行），不再是主视觉区。

未执行 Clean（约束：不真 clean 本机盘）；仅列盘 + 布局验证。

## Commit

- message：`feat(firpe-cleaner): 系统盘可清除（FirPE 场景去除系统盘排除）+ UI 布局（列表放大+滚动+日志缩小）`
- hash：`3baae141272bf05a82ebaac95e6ad4b5f79ba6cc`
