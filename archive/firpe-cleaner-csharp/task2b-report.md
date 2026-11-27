# Task 2b 报告 — Core 磁盘枚举 review 问题修复

日期：2026-11-26
状态：**DONE**
Commit：`fb3e44a`
（仅改动 `firpe-cleaner/` 的 Core 与 Tests，未 push）

## 一、修复说明

### Critical — diskpart 回退解析跨行误匹配必崩
- 根因：旧 `DiskRowRegex`（`^\s*(?:Disk|磁盘)\s+(\d+)(?:\s+\S+)*?\s+([\d.]+)\s+(B|KB|MB|GB|TB)`）中 `\s` 可跨行、`(?:\s+\S+)*?` 惰性扩展，从 `detail disk` 段头行"磁盘 0"跨行误匹配到卷表容量列（真实输出必有卷表，如"卷 1 … 550 MB"），产生重复盘号 → `ToDictionary` 抛 `ArgumentException`。
- 修复（双层）：
  1. `ParseDiskpartOutput` 重构为**逐行分段解析**：以脚本命令回显 `select disk N` 为界，`select` 之前仅 `list disk` 表段匹配盘行；进入 detail 段后不再匹配盘行。
  2. `DiskRowRegex` 改为**行内锚定**：全部空白用 `[ \t]`、中间用 `[^\r\n]*?`，正则本身不可能跨行。
  3. 纵深防御：盘行重复盘号直接丢弃（`byNumber.ContainsKey` 检查），即使未来正则回归也不会再崩。
- 实证：对含卷表中文样本，旧正则 5 个匹配（盘号 0、2 各重复一次），新正则恰好 3 个（list disk 三行，无重复）。

### Important — WMI 主路径补系统盘排除
- `EnumerateByWmi` 新增系统盘判定：`Win32_LogicalDisk.BootPartition=True`（通常 C:）→ 经 `Win32_LogicalDiskToPartition` 关联反查分区 → `DiskIndex` → 物理盘号，置 `IsBoot`，由 `Filter` 标 `IsExcluded` + 原因"系统盘（启动盘）"。非 PE 桌面运行时系统盘不再列入可清理。WinPE 启动盘=USB 由 BootPartition 判定同样覆盖。

### Minor
1. **Size null 不误标 <1GB**：新增 `DiskInfo.SizeUnknown`，WMI `Size` 为 null 时置位，`Filter` 标注"容量未知"（原逻辑会把 SizeGB=0 误标"容量小于 1GB"）。
2. **FreeSpace null 不按 0 计入**：`logicalFree` 只在 `FreeSpace` 非 null 时录入，归并时 `TryGetValue` 失败即不计入；盘上所有映射分区 FreeSpace 均 null 时 `FreeGB` 保持 null（显示"—"）。
3. **USB 判定用不区分大小写包含**：新增 `BusIsUsb`（`Bus.Contains("USB", OrdinalIgnoreCase)`），覆盖 UAS 等大小写/前缀变体。

### 测试基础设施
- Core csproj 增加 `InternalsVisibleTo("FirpeCleaner.Tests")`，使测试可访问 `internal DiskInfo.IsBoot`（启动盘过滤用例需要）。

## 二、新增/增强测试

- `ParseDiskpartOutput_ChineseRealisticWithVolumeTable_NoDuplicateNumbers`（**新增**）：贴近真实的中文 `list disk` + `detail disk`（含卷表段"卷 0 … 476 GB / 卷 1 … 550 MB"），断言无重复盘号、盘 0 容量仍 476 GB（不被卷行 550 MB 污染）、`IsBoot` 正确。旧代码在此样本上必崩（重复盘号 → ToDictionary）。
- `ParseDiskpartOutput_ExtractsNumbers`（增强）：补断言 `disks[0].IsBoot`（"Boot Disk : Yes"）与 `disks[2].IsBoot` 为 false。
- `Filter_ExcludesBootDiskByIsBoot`（新增）：IsBoot 盘排除、原因含"系统盘"。
- `Filter_UsbMatchIsCaseInsensitiveContains`（新增）：`Bus="Usb"` 被排除（大小写不敏感包含），`SCSI` 保留。
- `Filter_UnknownSizeMarksUnknownNotUnder1Gb`（新增）：`SizeUnknown` 标注"容量未知"（不含"1GB"），确知 <1GB 仍标"容量小于 1GB"。

## 三、测试输出

```
dotnet build FirpeCleaner.sln -c Debug
已成功生成。 0 个警告  0 个错误

dotnet test FirpeCleaner.sln -c Debug --no-build
已通过! - 失败: 0，通过: 6，已跳过: 0，总计: 6，持续时间: 25 ms - FirpeCleaner.Tests.dll (net8.0)
```

## 四、Commit

```
fb3e44a fix(firpe-cleaner): Core 磁盘枚举修复 review 问题（diskpart 正则跨行必崩/系统盘排除/Size-null/FreeSpace-null/USB 匹配）
```

## 五、Concerns

- WMI 路径的系统盘判定与 FreeSpace-null 归并依赖真实 WMI，无法单测，仅通过代码评审与 Filter/Parse 侧用例覆盖；建议 Task 3+ 若做 GUI 可在真机冒烟验证一次。
- diskpart 回退路径需管理员权限，本机无法真机实测（与 task2-review 一致）；解析层已用含卷表真实形态样本覆盖。
