# Task 4b 报告 — 修复 Core 枚举 WMI BootPartition Bug

## 状态

**DONE**

## 修复说明

### 根因（reviewer 三重实证复述）

`DiskEnumerator.EnumerateByWmi()` 旧实现（DiskEnumerator.cs L169-171）遍历
`Win32_LogicalDisk` 读 `BootPartition` 判定系统盘，但该属性属 `Win32_DiskPartition`
（LogicalDisk 无此属性）→ C# 索引器访问 `mo["BootPartition"]` 在第一次迭代即抛
`WBEM_E_NOT_FOUND` → 被 `Enumerate()` L33 catch → 任何标准 Windows/WinPE 上 WMI 主路径
100% 回退 diskpart（Model/SN/Media/FreeGB 全丢、剩余容量恒 "-"；非管理员环境枚举整体失败）。

本机复验（2026-11-26）：

```text
Win32_DiskPartition 中 BootPartition=True 的分区：
  DeviceID      : Disk #0, Partition #0
  DiskIndex     : 0
  BootPartition : True

Win32_LogicalDisk 中名为 BootPartition 的属性数：0
```

### 修改（`firpe-cleaner/src/FirpeCleaner.Core/DiskEnumerator.cs`）

1. **系统盘判定重写**：原「LogicalDisk.BootPartition → 关联反查分区 → DiskIndex」整段
   替换为直接遍历 `Win32_DiskPartition`（该查询本就已一次性取回，含 DeviceID/DiskIndex），
   取首个 `BootPartition=True` 分区的 `DiskIndex` 作为系统盘号（`Win32_DiskDrive.Index`
   与之匹配）。语义与 diskpart 回退路径的 `detail disk` "Boot Disk: Yes" 一致（同样置
   `IsBoot` 供 Filter 按"系统盘（启动盘）"排除）。
2. **新增可测辅助方法** `public static int FindBootDiskIndex(IEnumerable<(int DiskIndex, bool? BootPartition)>)`：
   返回首个 `BootPartition=True` 分区的 DiskIndex，无启动分区返回 -1；`BootPartition` 为
   null（属性无值）按非启动分区跳过。`EnumerateByWmi` 经
   `partitions.Select(p => (GetInt(p, "DiskIndex") ?? -1, GetBool(p, "BootPartition")))`
   调用，判定逻辑与生产代码同一实现、可单测。

`Win32_LogicalDisk`/关联/FreeSpace 归并逻辑不受影响（partToLogical/logicalFree 仍用于
剩余容量按盘归并）。

### 测试（`firpe-cleaner/tests/FirpeCleaner.Tests/DiskEnumeratorTests.cs`，+3 用例）

- `FindBootDiskIndex_ReturnsDiskIndexOfBootPartition`：假分区数据 `(0,false)/(1,true)/(2,null)`
  → 返回 1（IsBoot 判定正确）。
- `FindBootDiskIndex_NoBootPartition_ReturnsMinusOne`：全非启动分区 → 返回 -1，不标系统盘。
- `FindBootDiskIndex_MultipleBootPartitions_TakesFirst`：双启动分区取首个，与 diskpart
  首个 "Boot Disk: Yes" 语义一致。

## 本机枚举验证输出（WMI 主路径）

验证方式：临时探针测试（提交前已删除）直接调 `DiskEnumerator.Enumerate()` 走真实 WMI 主路径，
断言列盘成功且 Model 非空（diskpart 回退拿不到 Model，Model 非空即证明走的是 WMI 主路径）。
本机为非管理员环境（旧实现下 diskpart 回退提权失败 → 枚举整体失败返回 0 盘）。

```text
[probe] Enumerate() 返回 1 块盘
[probe] Disk 0: Model=[YMTC YMSS2ED06B66MC] SN=[A428_B772_BD31_0009.] Media=[Fixed hard disk media] Bus=[SCSI] SizeGB=477 FreeGB=234 IsBoot=True IsExcluded=True (系统盘（启动盘）)
```

结论：WMI 主路径不再抛异常；真实列盘成功，Model/SN/Media 全部取到，FreeGB=234（非 null，
不再是 "-"）；IsBoot=True 与本机 `Win32_DiskPartition` BootPartition=True 分区的
DiskIndex=0 完全吻合（系统盘排除生效）。非管理员环境枚举正常。

## 测试输出

```text
已通过! - 失败:     0，通过:    14，已跳过:     0，总计:    14，持续时间: 1 s - FirpeCleaner.Tests.dll (net8.0)
```

14 用例 = 既有 6（Filter×4 + ParseDiskpartOutput×2）+ CleanRunner×5 + 新增 BootPartition 判定×3，全 PASS。

## 构建输出

```text
已成功生成。
    0 个警告
    0 个错误
```

`dotnet build FirpeCleaner.sln -c Debug`（Core + Tests + GUI 三项目）0 warning 0 error。

## Commit

- hash：见下方返回（一次 commit，message 用 brief 指定的）
- 范围：仅 `firpe-cleaner/src/FirpeCleaner.Core/DiskEnumerator.cs` +
  `firpe-cleaner/tests/FirpeCleaner.Tests/DiskEnumeratorTests.cs`；未 push。

## Concerns

- 多启动分区场景 WMI 主路径只取首个 BootPartition=True 分区所在盘（旧实现同为取首个），
  diskpart 回退会标记所有 "Boot Disk: Yes" 盘；两者在单系统/常规双启动下无差异，极端
  双启动多盘场景行为略不同（属既有语义，未扩大改动）。
- `GetBool` 对 `Win32_DiskPartition.BootPartition` 的访问经本机真实实例验证无异常；
  WinPE 下 WMI 组件缺失仍会走既有 diskpart 回退兜底，行为不变。
