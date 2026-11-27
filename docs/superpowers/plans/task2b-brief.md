# Task 2b brief — 修复 reviewer 发现的 Critical/Important/Minor

## 背景

Task 2 review 结论 Needs fixes（1 Critical + 1 Important + 3 Minor）。修复后才能进 Task 3。

## 问题清单（来自 firpe-cleaner/task2-review.md，精确）

### Critical：DiskEnumerator.cs:343 DiskRowRegex 跨行误匹配 → 真实机器必崩
- 现象：`\s` 可跨行 + 惰性量词，从 `detail disk` 段头行"磁盘 0"跨行误匹配到卷表容量列
  （真实输出必有卷表，如"卷 0 … 550 MB"）→ 重复盘号条目 → ToDictionary 抛 ArgumentException
  → diskpart 回退路径（WinPE 无 WMI 时唯一路径）必崩。
- 修复：**逐行解析**（按行拆分，盘行只在 `list disk` 表段内匹配；detail 段单独解析），
  或正则加行锚定（`^磁盘\s+(\d+)\s` 多行模式下锚定行首），杜绝跨行匹配。
- 必须补测试：贴近真实中文 list disk + detail disk（**含卷表段**）样本，断言无重复盘号、
  解析正确（当前测试样本缺卷表，掩盖缺陷——补上真实形态样本）。

### Important：WMI 主路径不排除系统盘
- 现象：仅 diskpart 路径设 IsBoot；WMI 主路径无系统盘排除 → 非 PE 桌面运行时系统盘
  列入可清理。
- 修复：WMI 路径补系统盘判定——用 `Win32_DiskDrive` 的 `Partitions`/签名 或
  `Win32_LogicalDisk`（BootPartition=True 的盘符所在盘）判定系统盘并排除
  （IsExcluded + ExcludeReason="System disk"）；PE 环境启动盘=USB 已由 USB 规则排除。

### Minor
1. Size null 误标"<1GB"：Size 为空时应标注未知而非 <1GB。
2. FreeSpace null 按 0 计入：归并时 null 分区不应按 0 求和（应 null 传播或跳过）。
3. USB 精确匹配漏 UAS 盘：Bus 判定用 Contains("USB") 或 InterfaceType 含 USB 前缀
   （UAS 盘 InterfaceType 可能为 "USB" 或含 USB）——用不区分大小写包含匹配。

## 任务

修改 `firpe-cleaner/src/FirpeCleaner.Core/DiskEnumerator.cs` + 测试，修复上述全部问题，
补真实形态测试样本（含卷表），`dotnet test` 全 PASS + build 0 warning，
一次 commit：`fix(firpe-cleaner): Core 磁盘枚举修复 review 问题（diskpart 正则跨行必崩/系统盘排除/Size-null/FreeSpace-null/USB 匹配）`

## 报告

写 `firpe-cleaner/task2b-report.md`：修复说明、新增测试样本、测试输出、commit hash。
返回：状态（DONE/BLOCKED）、commit hash、一行摘要、concerns。