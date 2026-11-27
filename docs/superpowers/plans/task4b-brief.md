# Task 4b brief — 修复 Core 枚举 WMI BootPartition Bug

## 背景

reviewer 实证核实（三重证据）：`DiskEnumerator.EnumerateByWmi()` 读 `Win32_LogicalDisk.BootPartition`，但该属性属于 `Win32_DiskPartition`（LogicalDisk 无此属性）→ WMI 主路径**在任何标准 Windows 上 100% 抛 WBEM_E_NOT_FOUND** → 实际全走 diskpart 回退（Model/SN/Media/FreeGB 全丢、剩余容量恒 "-"；非管理员环境枚举整体失败）。

## 问题（来自 firpe-cleaner/task4-review.md，Important）

- 位置：`DiskEnumerator.cs` EnumerateByWmi 系统盘判定段
- 修复：改遍历 `Win32_DiskPartition`（读 `BootPartition=True` → `DiskIndex`）判定系统盘
  （DiskIndex 匹配 Win32_DiskDrive.Index），逻辑与 diskpart 回退路径的 IsBoot 一致
- 补测试：BootPartition 判定逻辑（构造假分区数据断言 IsBoot 正确）
- 验证：本机 WMI 主路径不再抛异常、真实列盘成功（管理员/非管理员均可枚举）

## 任务

修改 `firpe-cleaner/src/FirpeCleaner.Core/DiskEnumerator.cs` + 测试，`dotnet test` 全 PASS + build 0 warning，
一次 commit：`fix(firpe-cleaner): Core 枚举 WMI 系统盘判定改用 Win32_DiskPartition.BootPartition（修复 LogicalDisk 无该属性致主路径必崩）`

## 报告

写 `firpe-cleaner/task4b-report.md`：修复说明、本机枚举验证输出、测试输出、commit hash。
返回：状态（DONE/BLOCKED）、commit hash、一行摘要、concerns。