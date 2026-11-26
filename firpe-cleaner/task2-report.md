# Task 2 报告 — Core 磁盘枚举（WMI 主 + diskpart 回退 + 过滤 + 剩余容量）

日期：2026-11-26
状态：DONE

## 枚举实现说明

### 文件

- `src/FirpeCleaner.Core/DiskInfo.cs` — 行模型（public，属性可读）：
  `Number`（盘号→PhysicalDriveN）、`Device`（`\\.\PhysicalDriveN`）、`Sn`、`Model`、
  `SizeGB`（long，Round(Size/1024³)）、`FreeGB`（long?，分区归并；null=拿不到显示"—"）、
  `Bus`（InterfaceType）、`Media`、`IsExcluded`/`ExcludeReason`（排除盘仍列出但标注）、
  `IsHdd`（Media 含 HDD 或 Bus=SAS）。另有 `internal bool IsBoot`（diskpart 回退的启动盘标记，供过滤用）。
- `src/FirpeCleaner.Core/DiskEnumerator.cs` — 枚举器：
  - `Enumerate()`：先 WMI `Win32_DiskDrive`；WMI 抛异常或返回空 → 回退 diskpart
    （写临时脚本 `list disk` + 逐盘 `select disk N`/`detail disk`，`Process.Start("diskpart","/s:...")`
    捕获输出解析盘号/大小/总线/启动标记）。最后统一 `Filter` 标注排除，返回完整列表（不丢盘）。
  - 剩余容量：一次查询 `Win32_DiskPartition`（DiskIndex）+ `Win32_LogicalDisk`（FreeSpace）+
    `Win32_LogicalDiskToPartition` 关联映射，按盘号归并 FreeSpace → `FreeGB`（字节转 GB）；
    无分区或无逻辑盘映射 → null。
  - `Filter()`：排除 `Bus==USB`、Media 含 Removable/CD/DVD、`IsBoot`（系统盘/启动盘）、`SizeGB<1`。
    系统盘判定口径（按 brief）：WinPE 场景启动盘=USB 已被 USB 规则排除，SAS/SATA 内置盘非系统盘；
    diskpart 回退路径额外用 `detail disk` 的 "Boot Disk : Yes" 标记启动盘排除（真机/非 PE 兜底）。
  - diskpart 输出解析兼容英文/中文（`Disk|磁盘`、`Type|类型`、`Boot Disk|启动磁盘`、`Yes|是`）。
- `src/FirpeCleaner.Core/FirpeCleaner.Core.csproj` — 新增 NuGet 包 `System.Management 8.0.0`（WMI；仅 Windows，类标 `[SupportedOSPlatform("windows")]`，Core 不引用 WPF）。
- `tests/FirpeCleaner.Tests/DiskEnumeratorTests.cs` — 两个 xunit 测试（见下）。

### 测试

```
Filter_ExcludesUsbAndCdAndSmall()      PASS  — USB/Removable(DVD-CD)/<1GB 被排除标注，SATA/SAS 固定盘保留
ParseDiskpartOutput_ExtractsNumbers()  PASS  — list disk（中英文混合）盘号/大小解析 + detail disk Type 回填 Bus
已通过! - 失败: 0，通过: 2，已跳过: 0，总计: 2
```

`dotnet build FirpeCleaner.sln -c Debug`：0 警告 0 错误（含 WPF exe 项目，Core 变更未破坏脚手架）。

## 本机枚举输出（真实数据，序列号脱敏）

临时控制台调用 `DiskEnumerator.Enumerate()`（WMI 主路径）：

```
#0  Bus=SCSI    Media=Fixed hard disk media       Size=477GB  Free=234GB  Hdd=False  Sn=A428****  Model=YMTC YMSS2ED06B66MC  Excluded=False()
共 1 块盘
```

- 本机仅 1 块固定盘（SCSI/YMTC SSD 477GB），未误排除 ✓；`FreeGB` 分区归并正确（234GB）。
- 本机无 USB/CD/小盘，排除规则由单测覆盖；WinPE 真机验证时重点看 USB 启动盘被排除。

diskpart 回退路径：本机非提权环境运行 diskpart 报 740（需提升），无法本地实测；
解析逻辑已用混合中英文样本单测覆盖，WinPE（管理员运行，manifest requireAdministrator）真机验证。

## Commit

`feat(firpe-cleaner): Core 磁盘枚举（WMI 主+diskpart 回退+过滤+剩余容量）` — hash 提交后回填（同 task1 模式）。

## Concerns

1. diskpart 需管理员权限（本机 740）；WMI 与 diskpart 双失败时 `Enumerate()` 抛异常，GUI（Task 4）需捕获显示原因而非崩溃。
2. diskpart 输出的中文本地化字段为 best-effort 兼容（`磁盘/类型/启动磁盘`），若个别 WinPE 语言版本措辞不同，回退路径总线/启动标记可能解析不到——启动盘仍由 USB 规则兜底排除。
3. 系统盘判定依赖 WinPE 启动盘=USB 的口径（brief 明确）；非 PE 桌面环境运行本工具时，仅 diskpart 回退路径会排除启动盘，WMI 主路径不会（WMI 无 IsSystem 可靠字段）。
4. `IsHdd` 按 brief 口径（Media 含 HDD 或 Bus=SAS）；WMI 的 MediaType 通常为 "Fixed hard disk media"，多数盘 IsHdd=false，仅作标注不参与过滤。
