# Task 2b 审查报告 — Core 磁盘枚举修复复查

日期：2026-11-26
审查对象：commit `fb3e44a`（相对 `daa295c`；`fb3e44a` 单独改动 4 个文件，全部在 firpe-cleaner/ Core+Tests 内）
审查范围：`src/FirpeCleaner.Core/DiskEnumerator.cs`、`src/FirpeCleaner.Core/DiskInfo.cs`、`src/FirpeCleaner.Core/FirpeCleaner.Core.csproj`、`tests/FirpeCleaner.Tests/DiskEnumeratorTests.cs`
结论：**Approved**

---

## 一、合规核对

| 检查项 | 结果 | 说明 |
|---|---|---|
| C1（diskpart 正则跨行必崩）已修复 | ✅ | 逐行解析 + 行内锚定正则 + 重复盘号防御，实证无跨行误匹配（见下） |
| 补真实形态样本（中文 list disk + detail disk 含卷表段） | ✅ | `ParseDiskpartOutput_ChineseRealisticWithVolumeTable_NoDuplicateNumbers`：断言无重复盘号、盘 0 容量仍 476 GB（不被卷行 550 MB 污染）、IsBoot 正确 |
| I1（WMI 主路径系统盘排除）已修复 | ✅ | `BootPartition=True` 逻辑盘 → `Win32_LogicalDiskToPartition` 反查分区 → `DiskIndex` → `IsBoot` → `Filter` 排除"系统盘（启动盘）" |
| M1（Size null 不标 <1GB）已修复 | ✅ | 新增 `SizeUnknown`，Filter 标"容量未知"；`Filter_UnknownSizeMarksUnknownNotUnder1Gb` 覆盖 |
| M2（FreeSpace null 不按 0 计入）已修复 | ✅ | null 不录入 `logicalFree`，归并跳过 → 全 null 时 `FreeGB=null` |
| M3（USB 不区分大小写包含）已修复 | ✅ | `BusIsUsb`：`Contains("USB", OrdinalIgnoreCase)`，覆盖 UAS；`Filter_UsbMatchIsCaseInsensitiveContains` 覆盖 |
| 正则改动无新跨行/误匹配风险 | ✅ | 新 `DiskRowRegex` 仅用 `[ \t]` 与 `[^\r\n]`，物理上不可跨行；配合 `inDetail` 分段，双保险 |
| 重复盘号防御合理 | ✅ | `byNumber.ContainsKey` 检查后丢弃，即使未来正则回归也不会再触发 ToDictionary 崩溃 |
| 只改 firpe-cleaner/ Core+Tests | ✅ | `git diff 68774c4..fb3e44a`：仅 DiskEnumerator.cs / DiskInfo.cs / Core csproj / Tests 4 个文件 |
| 未 push | ✅ | `origin/main`=fc586cf（早于 daa295c），HEAD 领先 3 提交（daa295c/68774c4/fb3e44a）；无任何远端分支包含 fb3e44a |
| dotnet test 全 PASS / build 0 warning | ✅ | 复跑确认：6/6 通过；build 0 警告 0 错误 |
| 测试真验证行为 | ✅ | 新增 4 个测试均为真断言；卷表样本确能复现旧缺陷（实证见下） |

## 二、复跑验证记录

```
dotnet build FirpeCleaner.sln -c Debug
已成功生成。 0 个警告  0 个错误

dotnet test FirpeCleaner.sln -c Debug --no-build
测试总数: 6  通过数: 6（含 ParseDiskpartOutput_ChineseRealisticWithVolumeTable_NoDuplicateNumbers 等）
```

对真实形态中文样本（含卷表段"卷 0 … 476 GB / 卷 1 … 550 MB"）用新旧正则实证：

```
OLD 正则: 5 个匹配，盘号 0、2 各重复一次（detail 段头行"磁盘 0/磁盘 2"跨行误匹配到卷行容量）→ 旧代码必崩
NEW 正则: 恰好 3 个匹配（list disk 三行），无重复盘号
```

即新测试样本确实复现旧缺陷、修复后不再复现，回归防线有效。

## 三、修复实现复核

### C1 — diskpart 解析（双层防御，正确）
- `ParseDiskpartOutput` 重构为逐行状态机：以脚本命令回显 `select disk N`（英文，与系统语言无关）定位 `current` 并置 `inDetail`；`inDetail` 之前只匹配 `list disk` 表段盘行，进入 detail 段后只取 Type/启动磁盘行。第一遍（`list disk` 脚本）无 select 回显，全程只匹配盘行；第二遍（select+detail 脚本）无 list 表，按 select 回显建条目、补 Bus/IsBoot，调用方按盘号合并回 list 结果——两遍语义均正确。
- `DiskRowRegex` 改为行内锚定：全部空白用 `[ \t]`、中间用 `[^\r\n]*?`，正则自身不可能跨行（对整段文本匹配也不越行）；`^`+Multiline 在按行 Match 时等价行首锚定。`(?:Disk|磁盘)` 行首要求使卷表行"卷 N"、表头"磁盘 ###"（非数字）均不可能误匹配。
- 重复盘号防御：`byNumber.ContainsKey` 检查后丢弃，兜底不崩。
- detail 段 `TypeLineRegex`/`BootLineRegex` 均要求行首关键字 + 冒号，卷表行/表头不含该形态，无新误匹配面。

### I1 — WMI 系统盘排除（正确）
- 链路完整：`Win32_LogicalDisk.BootPartition=True`（通常 C:）→ 经 `Win32_LogicalDiskToPartition`（Antecedent=分区、Dependent=逻辑盘）反查分区 `DeviceID` → `Win32_DiskPartition.DiskIndex` → 物理盘号 → `IsBoot` → `Filter` 置 `IsExcluded` + 原因"系统盘（启动盘）"。非 PE 桌面运行时系统盘不再列入可清理。
- `GetBool` 容错（null/转换失败 → 跳过，不崩）；WinPE 启动 USB 若 BootPartition=True 同样被排除（口径：USB 启动盘不可清理），与 brief 一致。

### M1/M2/M3 — 均正确
- SizeUnknown 在 `Filter` 中置于 `<1GB` 判定之前，未知不误标；确知 <1GB 仍按容量排除。
- FreeSpace null 不入 `logicalFree`、归并 `TryGetValue` 失败即跳过且不记 `mappedByDisk` → 全 null 时 `FreeGB=null`（GUI 显示"—"）。
- `BusIsUsb` 对 null/空串安全，大小写不敏感包含，覆盖 UAS（InterfaceType 含 USB 前缀/变体）。

## 四、问题列表

### Critical
无。

### Important
无。

### Minor（仅记录，不阻塞）
1. WMI 系统盘判定依赖 `Win32_LogicalDiskToPartition` 关联完整性：若启动分区关联缺失，`systemDiskIndex` 保持 -1、系统盘不排除（静默降级，不崩）。实际挂载分区均有关联，风险极低；建议 GUI 阶段（Task 3+）真机冒烟验证一次。
2. 过滤优先级：BootPartition=True 的 USB 盘先命中"系统盘（启动盘）"而非"USB 移动盘"（原因文案差异，行为正确）。
3. diskpart 回退路径需管理员权限，本机无法真机实测（与 task2-review 一致）；解析层已用含卷表真实形态样本覆盖，复验通过。

## 五、结论

**Approved**。C1/I1/M1-M3 全部按要求修复，含卷表真实形态样本确能复现旧缺陷且修复后回归通过，正则改动无新跨行风险，重复盘号防御合理；仅改 firpe-cleaner/ Core+Tests，未 push；build 0 警告、测试 6/6 通过（本机复跑确认）。
