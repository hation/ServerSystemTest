# Task 2 brief — Core 磁盘枚举（WMI 主 + diskpart 回退 + 过滤）

## 背景

firpe-cleaner 的 Core 层磁盘枚举：WMI `Win32_DiskDrive` 主策略 + diskpart `list disk` 回退 + 过滤（排除 USB/CD/系统盘/<1GB），剩余容量 WMI 分区归并。

## 需求来源

- Spec：`docs/superpowers/specs/2026-11-26-firpe-cleaner-gui-design.md` §4
- Plan：`docs/superpowers/plans/2026-11-26-firpe-cleaner-gui.md` Task 2

## 任务（精确，基于 HEAD=849b90e）

### 1. `firpe-cleaner/src/FirpeCleaner.Core/DiskInfo.cs`
行模型（public，属性可读）：
- `int Number`（盘号 → PhysicalDriveN）
- `string Device`（`\\.\PhysicalDriveN`）
- `string Sn`
- `string Model`
- `long SizeGB`（总容量，Round(Size/1GB)）
- `long? FreeGB`（剩余容量，分区归并；null=拿不到显示"—"）
- `string Bus`（InterfaceType：USB/SCSI/SATA/NVMe/IDE…）
- `string Media`（Fixed Hard Disk / Removable…）
- `bool IsExcluded` + `string ExcludeReason`（排除盘仍列出但标注，GUI 不勾选）
- `bool IsHdd`（Media=HDD 或 Bus=SAS）

### 2. `firpe-cleaner/src/FirpeCleaner.Core/DiskEnumerator.cs`
- `static IReadOnlyList<DiskInfo> Enumerate()`：
  1. WMI `ManagementObjectSearcher("SELECT * FROM Win32_DiskDrive")` → 映射 DiskInfo；
     剩余容量：对每盘查 `Win32_DiskPartition`（DiskIndex=Number）拿分区，再映射
     `Win32_LogicalDisk`（DeviceID 对应分区）汇总 FreeSpace；失败/无分区 → FreeGB=null
  2. WMI 抛异常（不可用）→ 回退 diskpart：写临时脚本 `list disk`+`detail disk`，
     `Process.Start("diskpart","/s:...")` 捕获输出解析盘号/大小/总线
  3. 返回含排除标记的完整列表（不丢盘，排除盘 ExcludeReason 标注）
- `static void Filter(...)` 或 Enumerate 内联：排除 `Bus=="USB"`、
  `Media` 含 Removable/CD/DVD、系统盘（WMI `Win32_DiskDrive` 无 IsSystem——用
  **启动介质判定**：diskpart 输出中系统盘/或 WMI `Win32_ComputerSystem`/物理盘
  与 boot 盘匹配——**实现时用可靠口径**：WinPE 场景启动盘=USB 已被排除，SAS/SATA
  内置盘非系统盘；`Size<1GB` 排除）

### 3. `firpe-cleaner/tests/FirpeCleaner.Tests/DiskEnumeratorTests.cs`
- `Filter_ExcludesUsbAndCdAndSmall()`：构造假列表 → 断言 USB/Removable/<1GB 被排除标记
- `ParseDiskpartOutput_ExtractsNumbers()`：喂 `list disk` 示例文本 → 断言盘号/大小解析
- WMI 真实枚举不做单测（环境依赖），留 GUI 冒烟/真机验证

### 4. 验证
- `dotnet test`（tests 引用 Core）→ 全 PASS
- 临时控制台（或临时 test）打印本机 `Enumerate()` 结果（真实数据，验证过滤）——只打印不清理

### 5. Commit
`feat(firpe-cleaner): Core 磁盘枚举（WMI 主+diskpart 回退+过滤+剩余容量）`

## 环境

- dotnet 8 SDK（PATH 或 C:\Program Files\dotnet\dotnet.exe）
- 仓库根 ServerSystemTest，只改 firpe-cleaner/
- Core 不引用 WPF（System.Management 需 NuGet 包 `System.Management`——在 Core csproj 加）

## 禁止

- 不改 GUI（MainWindow 等）
- 不做任何清理动作（枚举只读）
- 不 push

## 报告

写 `firpe-cleaner/task2-report.md`：枚举实现说明、本机枚举输出（脱敏盘号）、测试输出、commit hash。
返回：状态（DONE/BLOCKED）、commit hash、一行摘要、concerns。