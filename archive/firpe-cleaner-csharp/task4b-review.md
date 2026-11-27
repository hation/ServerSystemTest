# Task 4b 审查报告 — Core 枚举 WMI BootPartition 修复（commit 87e1b30，base bda9558）

- 审查对象：`firpe-cleaner/src/FirpeCleaner.Core/DiskEnumerator.cs` + `firpe-cleaner/tests/FirpeCleaner.Tests/DiskEnumeratorTests.cs`（commit `87e1b30`，相对 `bda9558`）
- 审查方式：只读。逐行读源码/测试 + `git diff bda9558 87e1b30` 核对改动范围 + `dotnet test`/`dotnet build` 复跑 + 本机 WMI schema 复核
- 结论：**Approved**

## 1. 修复正确性 ✅

| 要求 | 结果 |
|------|------|
| 系统盘判定改遍历 Win32_DiskPartition 读 BootPartition=True → DiskIndex | ✅ diff 确认：旧「LogicalDisk.BootPartition → 关联反查分区 → DiskIndex」整段删除（旧代码确实 `GetBool(l, "BootPartition")` 读 LogicalDisk，证实现有 bug），替换为 `FindBootDiskIndex(partitions.Select(p => (GetInt(p, "DiskIndex") ?? -1, GetBool(p, "BootPartition"))))`。`Win32_DiskPartition.DiskIndex` 与 `Win32_DiskDrive.Index` 匹配（WMI schema 语义），置 `IsBoot` 供 Filter 按系统盘排除，与 diskpart 回退路径语义一致 |
| 不再读不存在的 LogicalDisk.BootPartition | ✅ `GetBool`/`GetInt` 现仅访问 `Win32_DiskPartition`（DeviceID/DiskIndex/BootPartition）与 `Win32_DiskDrive`（Index/InterfaceType/MediaType/Size/SerialNumber/Model），全部 schema 实证存在的属性 |
| WMI 主路径不再必抛 | ✅ 本机复核（2026-11-26）：`Win32_DiskPartition` 有 BootPartition 属性（1 个），本机 `Disk #0, Partition #0` = `{BootPartition=True, DiskIndex=0}`；`Win32_LogicalDisk` 的 BootPartition 属性数 = 0。C# 索引器访问存在的属性不抛 WBEM_E_NOT_FOUND，原必抛路径消除 |
| 本机真实列盘成功 | ✅ 修复报告探针输出：`Enumerate()` 返回 1 盘，Model=`YMTC YMSS2ED06B66MC`、SN/Media 全取到、FreeGB=234（非 null）、IsBoot=True 盘 0 与本机 BootPartition 分区 DiskIndex=0 吻合；非管理员环境 WMI 主路径列盘成功（Model 非空即证明未走 diskpart 回退） |

## 2. FindBootDiskIndex 抽取正确性 ✅

- `public static int FindBootDiskIndex(IEnumerable<(int DiskIndex, bool? BootPartition)>)`：public static 签名，可单测 ✅
- 多启动取首个：`foreach` 遇到首个 `BootPartition is true` 即 return，取首个 ✅
- 无启动返回 -1：全 false/null 走完循环返回 -1 ✅
- null 按非启动跳过：`is not true` 对 null 同样成立（`null is not true` → true → continue）✅
- 生产代码与测试走同一实现：判定逻辑单测有效 ✅

## 3. 补测试 ✅（+3 用例，真验证判定逻辑）

| 用例 | 输入 | 期望 | 结果 |
|------|------|------|------|
| `FindBootDiskIndex_ReturnsDiskIndexOfBootPartition` | `(0,false)/(1,true)/(2,null)` | 1 | ✅ 覆盖 true 命中 + null 跳过 |
| `FindBootDiskIndex_NoBootPartition_ReturnsMinusOne` | `(0,false)/(2,null)/(3,false)` | -1 | ✅ |
| `FindBootDiskIndex_MultipleBootPartitions_TakesFirst` | `(0,true)/(1,true)` | 0 | ✅ |

三个用例覆盖 FindBootDiskIndex 全部核心分支（命中/跳过/null/多启动取首/无启动 -1），真验证判定逻辑。

## 4. 构建与测试复跑 ✅

- `dotnet test FirpeCleaner.sln -c Debug`（本人复跑）：**已通过! 失败 0，通过 14，跳过 0，总计 14** ✅（= 既有 Filter×4 + ParseDiskpartOutput×2 + CleanRunner×5 + 新增 3）
- `dotnet build FirpeCleaner.sln -c Debug`（本人复跑）：**0 警告 0 错误**（Core + Tests + GUI 三项目）✅

## 5. 范围与 git 状态 ✅

- `git show --stat 87e1b30`：仅 3 文件 —— `src/FirpeCleaner.Core/DiskEnumerator.cs`、`tests/FirpeCleaner.Tests/DiskEnumeratorTests.cs`、`firpe-cleaner/task4b-report.md`（报告，brief 要求）。只改 Core + Tests + 报告 ✅
- commit message 与 brief 指定完全一致 ✅；`main [ahead 40]`，未 push ✅

## 6. 问题列表

### Critical
- 无

### Important
- 无

### Minor（观察项，均不可达/既有语义，非阻塞）
1. **BootPartition=True 但 DiskIndex 缺失的理论边界**：`GetInt(p, "DiskIndex") ?? -1` 若磁盘索引缺失会把 boot 分区映射为 -1，`FindBootDiskIndex` 直接返回 -1 → 误判"无系统盘"而非跳过继续找下一个（旧代码对 -1 会继续外层循环）。但 `Win32_DiskPartition.DiskIndex` 是必有的 UInt32 属性（SELECT * 恒返回），实际不可达；且失败方向是"少排除"而非"误排除错盘"，安全。
2. **多启动多盘语义差异（报告已自述）**：WMI 主路径只取首个 BootPartition=True 盘，diskpart 回退会标记所有 "Boot Disk: Yes" 盘。单系统/常规双启动无差异；极端双启动多盘行为略不同，属既有语义（旧实现同为取首个），未扩大改动，符合 brief。
3. **WinPE 缺 WMI 组件兜底不变**：`Enumerate()` L33 顶层 catch 仍负责 WMI 不可用时回退 diskpart，新判定逻辑不影响该路径。

## 7. 结论

**Approved**。修复正确：系统盘判定改读 `Win32_DiskPartition.BootPartition`（本机 schema 实证属性存在、LogicalDisk 无此属性），WMI 主路径不再必抛，本机真实列盘成功且 IsBoot 与分区表吻合；`FindBootDiskIndex` 抽取正确（public static、多启动取首、无启动 -1、null 跳过）；+3 测试覆盖全部判定分支；本人复跑 dotnet test 14/14 PASS、build 0 warning 0 error；范围仅 Core+Tests+报告，未 push。
