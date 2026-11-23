# 盘定位表与 SN 采集设计（disk-map / SN）

日期：2026-11-23
状态：待评审

## 1. 意图与背景（Why）

本次排查中，压测 error.log 报错只记录设备名（如 `nvme2n1`），无法直接对应到物理盘；要定位"是哪块盘"，只能手工翻 HDM 的 `nvme_info.ini`，用 SN 跨系统比对，成本高且容易漏。

目标：**压测出问题后，从日志和报告直接定位是哪块物理盘（SN），无需再手动翻 HDM 日志。**

## 2. 目标 / 非目标 / 反目标

### 目标
1. 压测启动时生成盘定位基础表 `disk-map.txt`（OS 侧采集：设备名 + SN + 挂载点），每次压测都生成，与 run-config.txt / info-before.txt 同目录。
2. error.log 报错行**直接标注 SN**：设备名旁追加 `(SN=xxx)`，原始记录即含盘标识。
3. 复盘结论层（summary / review）报错设备自动带 SN。
4. sds-log-parser 接入 `nvme_info.ini` 解析（SN / Front slot / PCIe slot / 链路状态 / 剩余寿命），作为"按 SN 补齐 HDM 信息"的现成能力，体检报告中呈现 NVMe 盘表。

### 非目标（用户明确不做的）
- **不做**期望清单自动比对告警：用户现场自行核对盘数量，数量一致即开测，测完统一排查。
- **不强制** HDM 侧补齐：disk-map.txt 先只有 OS 侧字段；Front slot / PCIe slot / 链路状态由 sds 解析后按 SN 可选补齐。
- 不改变现有 error.log 的归因/判定逻辑（I/O 错误优先于 status=OK 等），只在其上附加 SN 标注。

### 反目标（做了即失败）
- 换 Linux 发行版后 SN 采集失效（禁止依赖必须安装的 nvme-cli/smartctl）。
- 改动破坏现有压测编排、错误判定、报告格式。
- 不兼容旧版本生成的结果目录（无 disk-map.txt 时优雅降级，不报错）。

## 3. 约束

- 压测脚本为 bash，离线环境，运行时零第三方依赖（沿用现有"入口 + lib"结构，函数在 lib 中）。
- SN 采集必须零依赖：用 sysfs，不允许依赖 nvme-cli/smartctl（可作可选增强，装了用、没装降级）。
- 修改脚本后需同步 docs/ 的行号引用（README.md / operation-manual.md / 专项说明文档，按函数所在 lib 计）。
- sds-log-parser 为 Python 3.12 标准库，零第三方依赖，沿用现有模块结构（extract / inventory / health / report / ai）。
- 交付需重新打包 offline-stress-pkg 并递增版本号（功能新增 → 次版本号 +1，当前 v1.1.2 → v1.2.0），同时产出两个 zip。

## 4. 已确定的设计（How，用户已拍板）

### 4.1 压测侧：disk-map.txt 生成

**位置与时机**：压测任务启动时（`cmd_start` 写 run-config.txt / info-before.txt 的同一处），在结果目录生成 `disk-map.txt`。

**内容**：全机所有识别到的数据盘（不只本任务压的盘），每行：
```
设备名 | SN | 挂载点
nvme2n1 | SH231801357 | /mnt/HDD03
```
- 设备名：整盘名（nvme2n1 / sdb 等），与 devices.txt 口径一致
- 挂载点：`df -h` / `findmnt` 可得；未挂载盘留空
- 覆盖全机盘（含未挂载盘），因为 error.log 的"未归因"报错也可能来自其他盘，全机映射才能定位

**SN 采集方式（零依赖）**：
- NVMe：`readlink -f /sys/class/block/nvmeXn1/device` → nvmeX 目录 → `cat …/serial`
  - 即 `cat /sys/class/nvme/nvmeX/device/serial`（通过 block 节点的 device 软链定位 nvmeX）
- SATA/SCSI（sd*）：`/sys/class/block/sdb/device/` 下读 serial（若存在）；读不到则留空
- 可选增强：若 `nvme list` 可用，用其输出交叉校验（不依赖，仅增强）

**新增函数（放 stress-lib-devices.sh，与 write_devices_file 同组）**：
- `sn_of_dev <设备名>`：给定整盘名返回 SN（sysfs），失败输出空串
- `write_disk_map <输出路径>`：枚举全机盘，生成 disk-map.txt
- 测试缝：新增 `SYSFS_ROOT="${SYSFS_ROOT:-/sys}"` 变量（仿现有 EDAC_ROOT 先例，stress-test.sh L28/L55），sn_of_dev 全部经 SYSFS_ROOT 读取，便于单元测试与跨环境注入

**枚举范围**：全机 `lsblk -o NAME,TYPE,SERIAL,MOUNTPOINT`（TYPE=disk），SATA/SCSI 盘的 `device/` 目录无 serial 时 SN 留空（设计已留白），NVMe 盘从 block 节点 `device` 软链定位 nvmeX 再读 serial。

### 4.2 压测侧：error.log 直接标注 SN

**机制**：monitor-loop 增量写 `dmesg io:` 行到 error.log 时（stress-lib-monitor.sh 现有逻辑），对命中设备名查询 SN 并追加。

- **命中设备名提取**：现有归因正则 `dev_re`（stress-lib-monitor.sh L185-188）只做整行匹配、不返回命中设备名——实现时需对命中行再逐名匹配 devices.txt，取首个命中设备名（与归因口径一致），再调 `sn_of_dev`
- 有 SN：写入格式 `dmesg io (dev=nvme2n1 SN=SH231801357): <原始行>`；保持原 dmesg io: 前缀不变，仅附 SN
- 无 SN（sd* 读不到 / 非本机盘）：保持现状 `dmesg io: <原始行>`，不破坏
- error-unattributed.log（未归因）同样尝试标注 SN，标注方式相同

**注意**：monitor-loop 是增量读 dmesg 的，读到的设备名要先用 `sn_of_dev` 解析——磁盘映射在任务目录 disk-map.txt 中，sn_of_dev 优先读 sysfs 实时值（与 disk-map.txt 生成同源），保证实时准确。

### 4.3 压测侧：复盘结论层带 SN

- summary.txt / review 中"异常点"列出的 error.log 命中行，其 dmesg io 行已自带 SN（因 error.log 已标注），无需额外处理
- 如 summary 生成逻辑中有单独摘录设备名的环节，同步用 sn_of_dev 附 SN（若已有则跳过）

### 4.4 sds-log-parser 侧：解析 nvme_info.ini

**解析内容**（nvme_info.ini 每块 NVMe 一段）：
- SN（Serial Number / SN 字段）
- Phy Slot（Front slot 17 等，即物理槽位）
- PCIe Slot（Slot 37 等）
- Pd Status（Normal / 异常）
- Status Flags + BIT 描述（**链路状态：第一/第二端口 link up/down**，如 0xbb / 0xb3）
- Remaining Life / Composite Temperature / Historical Max Temperature

**改动点**：
- `sds_inventory.py`：新增 `nvme_disks` 字段（dataclass），解析 `static/nvme_info.ini`
  - **注意：不能复用现有 `_read_ini`（ConfigParser 默认 `allow_no_value=False`，样本含 "NVMe WEB Information" / "----" 裸行会解析失败返回空）**——需专用解析器：按 `[NVME: NVMe #N]` 段切分，逐段提取字段并过滤垃圾行
- `sds_report.py`：新增 NVMe 盘表（附录或整机信息中），列：SN / Phy Slot / PCIe Slot / 状态 / 链路状态 / 剩余寿命；链路 down 的盘在表中用醒目标记
- `sds_ai.py`：`build_ai_payload` 中附 NVMe 盘表（供 AI 综合分析使用）
- `sds_health.py`：**可选增强（建议做，非强制）**——把"NVMe 第一端口 link down"计入提示（非异常），与现有背板/事件规则并列；若实现需同步 health 测试

**链路状态判定**：读 BIT 行描述（`BIT3:The first port's PCIe link is up/down`）而非十六进制 Status Flags（0xbb/0xb3），语义更稳、跨固件兼容。

**交付物**：体检报告新增 NVMe 盘表章节 + ai-facts 附 NVMe 盘表。用户拿到 .sds 后即可按 SN 补齐 disk-map.txt 的 Front slot / PCIe slot / 链路状态。

## 5. 留给实现者的决策（Builder 自由裁量）

- disk-map.txt 表头/列格式的具体排版（管道分隔、对齐），保证与其他 .txt 风格一致即可
- sn_of_dev 对 sd* 盘的 serial 读取路径（不同发行版 sysfs 布局略有差异，读不到返回空）
- sds 报告中 NVMe 盘表的章节位置（附录 vs 整机信息），保持报告结构整洁即可
- monitor-loop 标注 SN 时对"重复报错行"的去重策略（保持现有行为，不新增去重逻辑）

## 6. 验证方式

- 压测侧：在测试机跑一次 hdd 任务，确认 disk-map.txt 生成且 SN 正确；构造一次 dmesg io 报错（或回放历史报错），确认 error.log 行带 SN；summary 复盘含 SN
- sds 侧：用现有 .sds 样本跑解析，确认报告出现 NVMe 盘表且 SN / 槽位 / 链路状态正确——**注意：Front slot 19 link down 的断言仅对 23.sds 成立**（另一个样本 M_20261123.sds 的 19 号槽是 0xbb/up，不得用它断言 down）
- 回归：现有 tests/run_tests.py 全绿（新增 test_nvme_* 用例，dataclass 新字段默认 list 不破坏现有断言）；旧结果目录（无 disk-map.txt）不报错
