# 硬盘压测对齐现场口径（分区/格式化 + I/O 错误判定）设计

- 日期：2026-11-16
- 状态：定稿（依据已确认需求 `docs/superpowers/notes/2026-11-16-hdd-stress-requirements.md`）
- 依据：`2026-11-16-hdd-stress-requirements.md`（FR-1~FR-11）、`2026-11-16-hdd-stress-gap-analysis.md`（R1~R9）
- 关联文件：`offline-stress-pkg/disk-mount.sh`、`offline-stress-pkg/stress-test.sh`、`offline-stress-pkg/oneclick.sh`、`README.md`、`operation-manual.md`、`offline-stress-pkg.zip`

## 1. 口径基线（不得偏离）

| 项 | 口径 | 来源 |
|---|---|---|
| 数据盘形态 | 重建时每盘 **1 个 GPT 分区**，对分区 `mkfs.ext4 -m 0 /dev/sdX1` | FR-1 |
| 默认模式 | **不清盘**：有分区→挂载该分区；分区无 fs→自动格式化该分区；整盘有 fs→直接挂载；空盘→整盘 `mkfs`（现状保留） | FR-2、口径表 |
| 多分区盘 | 默认**只测第一个分区**，计划中显式提示分区数量与“仅测第一个”；`--rebuild` 清整盘分区表重建为 1 个分区 | FR-11 |
| blkid 失败 | 重试 5 次（间隔 1s），仍失败**不格式化、跳过该盘**，继续其他盘，最终退出码 1 | FR-2 |
| 系统盘 | 永不分区/格式化/挂载；压测 `/stresstest-hdd`（根文件系统压测） | FR-10 |
| 判定 | 内核 I/O 错误命中即异常，覆盖 `status=OK`；按设备归因 | FR-5/6/7 |
| 挂载点 | 已占用编号不复用；`--rebuild` 仅在显式请求时发生 | FR-4/FR-8 |
| 时长/写入量 | 默认 10h；`--hdd 1 --hdd-bytes 10G` | 口径表 |

## 2. 目标

- `disk-mount.sh mount` 新增 `--rebuild`、`--dry-run`，并在默认模式下补齐“分区无文件系统自动格式化”“blkid 重试”“挂载点编号不复用”。
- `stress-test.sh` 新增内核 I/O 错误增量检测、按设备归因、结论优先级修正、ENOSPC 区分、系统盘口径说明。
- `oneclick.sh` 新增 `--rebuild` 透传与菜单一次确认。
- 既有 CLI 参数、结果目录结构、`monitor.csv` 列、`review` 输出字段保持兼容；旧套件全绿。

## 3. 非目标

- 不做安全擦除、坏道扫描、写盘头 signature。
- 不改 CPU/内存压测与判定。
- 不改默认时长与写入量。
- 不写 `/etc/fstab`，不做开机自动挂载。
- 不引入新依赖（仅用 Kylin 自带 util-linux/e2fsprogs/parted）。

## 4. 反目标（即使能跑也算失败）

- 未显式 `--rebuild`（或菜单输入 y）就清空任何数据盘。
- 系统盘出现在分区/格式化/挂载流程中。
- `blkid` 失败后仍执行 `mkfs` 或挂载。
- 在非挂载目录上启动压测。
- 默认模式静默只测多分区盘的第一个分区（必须显式提示）。
- 一块盘的 I/O 错误污染其他盘的结论。
- `status=OK` 覆盖已命中的 `error.log` 错误。
- 破坏既有 76/135/命令可见性/空格路径回归。

## 5. disk-mount.sh 设计

### 5.1 CLI 与环境变量

```
bash disk-mount.sh mount [--disks all|sdb,sdc|1,2] [--yes] [--rebuild] [--dry-run]
```

- `--rebuild`：重建模式（清分区表→建 1 分区→格式化分区→挂载分区）。
- `--dry-run`：等价于 `DRY_RUN=1`（保留环境变量兼容），只打印计划，不执行写操作、不写 `mount.log`；始终输出 `（DRY RUN，未执行）`，退出码与真实执行一致（含失败/失败跳过 → 1，全为良性跳过 → 0）。
- 系统盘识别 fail-closed：`SYS_ID_OK=0`（df `/` 非 `/dev/*`、`lsblk` 不识别、`pkname` 多行（RAID/多 PV）、上溯超限、最终非 `TYPE=disk`）时，非 dry-run 直接中止并退出 1，不执行任何写操作；dry-run 仅告警并继续打印计划。
- `--rebuild` 前置预检 `parted` 可用；缺失时直接报错退出（dry-run 仅告警）。
- 新增命令接缝（便于测试伪造，默认同系统命令）：
  - `PARTED_BIN`（parted）、`PARTPROBE_BIN`（partprobe）、`UDEVADM_BIN`（udevadm）、
    `MKFS_BIN`（mkfs.ext4）、`MOUNT_BIN`（mount）、`UMOUNT_BIN`（umount）、`DF_BIN`（df）。
  - 既有 `LSBLK_BIN`、`BLKID_BIN`、`MOUNT_LOG`、`SKIP_ROOT_CHECK` 保持不变。
  - 所有命令仍经 `run_log` 记录（命令 + 输出 + 结果码），`mount.log` 格式不变。
- `--yes` 语义不变；`--rebuild` 且非 `--yes` 时沿用现有一次 y/N 确认。
- 未知参数、盘含系统盘、盘不存在 → 退出码 1（现状）。

### 5.2 设备数据模型

`disk_lines` 每盘输出：`盘符 容量 分区数 是否挂载 首个可测分区名 首个分区容量`。

- 枚举 `TYPE=disk` 的 `sd*`、`nvme*`、`vd*`、`mmcblk*`；系统盘硬跳过。`mmcblkXboot0/boot1`、`rpmb` 不在枚举范围。
- 挂载状态与挂载点按**该盘子树**（分区/LVM/RAID/crypt 后代）解析，不只看整盘与一级分区。
- 首个可测分区 = 列表里第一个**非扩展分区**：msdos 扩展分区（`PARTTYPE` 为 `0x5`/`0xf`/`0x85`）只作容器，不参与挂载与格式化；`nparts` 仍统计全部分区用于提示。
- 新增 `pt_type`（`lsblk -no PTTYPE`）：用于识别“有分区表但解析不到可用分区”。
- 首个分区 = `lsblk` 列表中该盘第一个 `TYPE=part` 项（FR-11“第一个分区”）。
- 新增 `DISK_FPARTSZ[]` 保存首分区容量，用于计划提示。

### 5.3 挂载点编号（FR-4）

- 规划阶段先收集“已被占用的编号”：`$DF_BIN -P` 挂载点匹配 `^/mnt/HDD[0-9][0-9]*$` 的数字，与 `lsblk` 全部 `MOUNTPOINT` 匹配同规则的数字取并集（防 df 未列出时覆盖已挂载点）。
- 对未挂载的选中盘，按选择顺序分配**最小可用编号**（`/mnt/HDD%02d`），不覆盖已占用编号。
- 已挂载的盘保持原挂载点、不重新分配，计划行显示“已挂载（跳过）”。
- 每个盘分配完成后写日志：`[时间] assign: /dev/sdb -> /mnt/HDD01（整盘 sdb）`，供事后追溯。
- 计划与执行共用同一份计划数组（盘、动作、挂载点），避免二次计算产生分歧。

### 5.4 blkid 探测契约（FR-2）

新增函数 `probe_fs <dev>`，返回三态：

| 情况 | 判定 | 返回 |
|---|---|---|
| `blkid -s TYPE -o value <dev>` 标准输出非空 | 有文件系统（输出类型） | 0 |
| 输出为空，结果码 0 或 2，且 stderr 为空 | 无文件系统 | 1 |
| 其他（结果码非 0/2、stderr 非空、命令超时） | 探测失败 | 2 |

- 结果码 2 = util-linux 对“无签名”的标准返回；stderr 非空视为访问失败（设备忙/不存在/权限）。
- 调用形式固定为 `$BLKID_BIN -s TYPE -o value <dev>`，不新增 `-p` 等参数（兼容既有假件与用例）。
- `probe_fs_retry <dev>`：最多 5 次尝试，间隔 1 秒；期间 `udevadm settle` 可用时先调用一次。仍返回 2 → 该盘跳过（不格式化）。
- 探测发生在计划阶段，结果决定计划动作；执行阶段按计划执行，不再二次探测（保证“计划即执行”）。

### 5.5 默认模式（无 `--rebuild`）单盘决策

```text
子树有任意挂载点（分区/LVM/RAID 后代） → 跳过，不消耗编号
  全部挂载点匹配 /mnt/HDD[0-9][0-9]* → 原因“已挂载（跳过）”，不算失败
  存在非 /mnt/HDD* 挂载点              → 原因“存在非测试挂载点挂载（<mp>），跳过”，不算失败但显式提示
无挂载：
  有分区但只有扩展分区容器 → 跳过（计入失败），不自动格式化，提示用 --rebuild
  无分区但存在分区表（PTTYPE 非空） → 跳过（计入失败），不自动格式化，提示用 --rebuild
  有分区（nparts>0）：
  probe_fs_retry(首分区) = 有 fs → mount 首分区 → /mnt/HDDxx
  probe_fs_retry(首分区) = 无 fs → mkfs.ext4 -m 0 首分区 → mount 首分区
  probe_fs_retry(首分区) = 失败  → 跳过该盘（记“blkid 失败”），不 mkfs
无分区：
  probe_fs_retry(整盘) = 有 fs   → mount 整盘（不重新格式化，现状）
  probe_fs_retry(整盘) = 无 fs   → mkfs.ext4 -m 0 整盘 → mount 整盘（现状）
  probe_fs_retry(整盘) = 失败    → 跳过该盘（记“blkid 失败”），不 mkfs
```

- 多分区盘（nparts>1）计划行追加提示：
  `本盘有 N 个分区，默认仅测第一个（sdb1，xxxG）；需要整盘覆盖请用 --rebuild`
- 首分区容量 < `--hdd-bytes`（默认 10G）时追加提示：`首分区容量可能不足以写入 10G，可能 ENOSPC`（按容量字符串换算，无法换算时不提示）。
- 只格式化被选中的首分区，不触碰同盘其他分区。
- mount 失败：该盘标失败，不启动压测（由 `stress-test.sh` 的挂载点校验兜底），继续其他盘。

### 5.6 `--rebuild` 模式单盘步骤（FR-1）

```text
0) 该盘子树（分区/LVM/RAID/crypt 后代）存在任一非 /mnt/HDD* 挂载点 → 整盘跳过（计入失败）
1) 该盘在 /mnt/HDD* 下的挂载点：逐个 umount
   - umount 失败 → 跳过该盘（不执行 parted）
2) parted -s /dev/sdX mklabel gpt
3) parted -s /dev/sdX mkpart primary ext4 1MiB 100%
4) partprobe /dev/sdX
5) udevadm settle（不可用时 sleep 1）
6) 解析分区设备：lsblk -ln -o NAME,TYPE /dev/sdX 中第一个 TYPE=part → /dev/<name>
   - 最多 5 次、间隔 1 秒；仍解析不到 → 跳过该盘
7) mkfs.ext4 -m 0 <分区设备>
8) mount <分区设备> /mnt/HDDxx
```

- 不使用“盲拼 1”：NVMe（`nvme0n1p1`）、mmcblk（`mmcblk0p1`）由 `lsblk` 实际解析。
- 任一步失败 → 该盘记失败并跳过，**继续其他盘**；全部结束若有失败/跳过，退出码 1，并列出失败盘与原因。
- 重建计划行：
  `01  /dev/sdb  894G  重建：清空分区表 → 建 1 分区 → mkfs.ext4 -m 0 /dev/sdb1 → /mnt/HDD01`
- `parted` 不存在 → 直接报错退出（dry-run 仅告警；离线包依赖系统自带 parted，不做 fallback）。
- 系统盘在任何模式下都不进入该流程（第 5.2 节硬跳过）。

### 5.7 输出与退出码

- 计划段、执行段沿用现有中文文案风格；成功行保留 `已挂载 <盘> → /mnt/HDDxx`（既有测试断言依赖）。
- 新增跳过/失败汇总：
  - `因 blkid 失败跳过：sdb（5 次探测均失败，未格式化）`
  - `因非测试挂载点跳过：sdc（存在非 /mnt/HDD* 挂载点（/data），不重建）`
  - `重建失败跳过：sdc（parted 返回 2）`
- 退出码：0 = 全部成功或无需操作；1 = 用法/前置错误、含系统盘、存在失败或失败型跳过（blkid 失败、非测试挂载点、重建失败、挂载失败）。默认模式“已挂载（跳过）”与“存在非测试挂载点挂载（跳过）”为良性跳过，不影响 0。
- `--dry-run`：计划打印完整，末尾始终输出 `（DRY RUN，未执行）`，不写 `mount.log`；退出码按计划判定（含失败型跳过 → 1，否则 0）。

## 6. stress-test.sh 设计

### 6.1 挂载点校验（FR-3）

- 新增接缝 `FINDMNT_BIN="${FINDMNT_BIN:-findmnt}"`。
- hdd/combo 的每个压测目录（无论默认 glob 还是显式 `--dirs`）启动前校验：
  `$FINDMNT_BIN -n -o SOURCE --target <dir>` 必须非空，且不等于根设备（`$DF_BIN -P /` 第 2 行第 1 列）。
- 不通过：打印 `目录 <dir> 不是已挂载的独立文件系统（设备=…，系统盘=…），不能作为压测盘`，退出码 1，不启动任何 stress、不建结果目录。
- 原先仅对默认 glob 生效的校验扩展到显式 `--dirs`（FR-3 验收要求）。

### 6.2 设备归因文件（FR-6）

`start hdd|combo` 在启动 stress 前，为结果目录写 `devices.txt`：

```
sdb1
sdb
```

- 每个压测目录：`SOURCE=$($FINDMNT_BIN -n -o SOURCE --target "$d")`；`basename` 为分区名；再去掉末尾 `p?[0-9]+` 得整盘名（`/dev/nvme0n1p1` → `nvme0n1`）。
- 系统盘（`--sysdisk`）：按根文件系统归因，`--target /`，同样写 basename 与整盘名（`/dev/mapper/vg-lv` → `vg-lv`，无整盘名则只写一行）。
- 解析失败或 `FINDMNT_BIN` 不可用：不写该类行；文件为空表示“不做设备过滤”（兼容旧目录）。
- 文件名固定 `devices.txt`，每行一个设备名（不含 `/dev/`），去重保序。

### 6.3 内核 I/O 错误检测（FR-5）

`monitor-loop` 的 dmesg 增量段拆成两类：

- OOM（沿用）：`oom|out of memory|killed process|Killed`。
- I/O 错误（新增，大小写不敏感）：
  `EXT4-fs error|EXT4-fs .*error|I/O error|Buffer I/O error|blk_update_request|critical medium error|ata[0-9.]+: .*(failed|error)|nvme[0-9]+.*(error|timeout|reset)|reset .*failed`

处理顺序（同一行只记一次）：

1. 命中 I/O 正则 → 设备归因：
   - `devices.txt` 非空：行内匹配任一设备名（边界匹配，避免 `sdb1` 命中 `sdb10`）→ 写入 `error.log`：`[时间] dmesg io: <原始行>`。
   - 未匹配（未归因）→ 写入 `$dir/error-unattributed.log`：`[时间] dmesg io 未归因: <原始行>`，不进 `error.log`、不改变结论。
   - `devices.txt` 为空/不存在：不过滤，直接写 `error.log`（旧目录兼容）。
2. 未命中 I/O 且命中 OOM → 沿用 `[时间] dmesg: <行>`，`oom_seen=1`。

- 边界匹配实现：把设备名合成 ERE `(^|[^[:alnum:]])(sdb1|sdb)([^[:alnum:]]|$)`，用 `grep -E -i`。
- dmesg 不可用时保持现状：跳过检测、不误报。
- `status.txt` 新增 `io=yes|no`（`io_seen` 标记），其余字段不变。

### 6.4 结论优先级（FR-7）

`cmd_review` 判定顺序：

1. `error.log` 命中（`grep -qE '检测到 stress|dmesg'`）→ **异常**（无论 `status.txt` 的 `state`，包括 `OK`）。
2. 否则检测 ENOSPC：`error.log`、`error-HDD*.log`、`error-SYSDISK.log` 中命中 `No space left on device` → `异常（空间不足 ENOSPC，非磁盘故障）`。
3. 否则按 `status.txt`：`OK` → 正常；`FAILED` → 异常（退出码非 0）；`ABORTED` → 异常（按 reason）；`STOPPED` → 已手动停止。
4. 无 `status.txt` → 沿用旧逻辑（退出码缺失/非 0/error.log 命中 → 异常，否则正常）。

- 异常时 `summary.txt` 的“异常点”段追加：
  - `error.log 命中（前 3 条）:` + 命中行（`grep -E '检测到 stress|dmesg' | head -3`）
  - 若存在未归因文件：`未归因内核 I/O 错误 N 条（error-unattributed.log，不计入本盘结论）`
- 删除原“`state=OK` 直接判正常”的短路（FR-7 验收核心）。

### 6.5 系统盘口径与覆盖边界（FR-10）

- 系统盘压测目录保持 `/stresstest-hdd`，不分区、不格式化、不挂载（现状）。
- `run-config.txt` 在 `sysdisk=1` 时新增：
  - `压测对象: 系统盘（根文件系统压测）`
  - `覆盖边界: 不覆盖 /boot、/boot/efi、swap、未分配空间；LVM/RAID 下写入可能跨多个物理盘`
- `summary.txt` 若 `run-config.txt` 含上述行则原样回显（FR-10 验收）。
- ENOSPC 结论按 6.4 与其他盘故障区分。

### 6.6 兼容性

- CLI 参数、结果目录名、`monitor.csv` 列、`review` 现有字段不变；`summary.txt` 仅新增行。
- 旧结果目录没有 `devices.txt` → I/O 错误不过滤（6.3），可正常 `review`。
- 新增接缝 `FINDMNT_BIN` 默认 `findmnt`，不改变生产行为。

## 7. oneclick.sh 设计（FR-8）

- 新增选项 `--rebuild`（可与 `all`/`hdd` 组合）。
- `do_mount` 组装的 argv 按开关追加 `--rebuild`：
  `bash disk-mount.sh mount --disks all --yes [--rebuild]`。
- 菜单选择 1（全测）/2（只测硬盘）时，启动前询问一次：
  `是否重新分区并格式化数据盘？(y/N)`，默认 N；输入 `y` 才向 `do_mount` 传 `--rebuild`。若启动时已显式带 `--rebuild`，菜单不再询问，直接沿用。
- CLI 未带 `--rebuild` 时输出提示：`未指定 --rebuild，本次复用已有文件系统；如需重建请加 --rebuild`。
- CLI `sysdisk|cpu|mem` 带 `--rebuild`：忽略并提示“仅对 all/hdd 生效”。
- 挂载返回非 0 的处理（配合 FR-2“跳过盘不中断其他盘”）：
  - `all`：警告后继续（现状）。
  - `hdd`：先枚举 `collect_hdd_dirs`；有挂载点则警告并继续；一个都没有才 `die`（不再“挂载返回非 0 即退出”）。
  - 挂载退出码记入 `MOUNT_RC`：批次 `summary.txt` 标注 `自动挂载: 正常` 或 `自动挂载: 存在跳过/失败盘（退出码 N，未挂载盘未参与压测）`；批次最终退出码为 1（即使各任务复盘正常）。
- `commands.txt`/`commands.sh` 经 `show_run` 自动包含 `--rebuild`，无需额外改动。
- `usage` 与菜单说明补充 `--rebuild`。

## 8. 测试计划

新增目录 `.superpowers/sdd/2026-11-16-hdd-align-field/tests/`，沿用 `lib.sh` 风格（假命令注入 PATH / 接缝变量）。

### 8.1 disk-mount.sh

| 编号 | 场景 | 期望 |
|---|---|---|
| D1 | 默认模式：有分区且有 fs | 只 `mount <分区>`，无 parted/mkfs |
| D2 | 默认模式：有分区、无 fs | 依次 `mkfs.ext4 -m 0 <分区>` → `mount <分区>` |
| D3 | 默认模式：无分区、无 fs | `mkfs.ext4 -m 0 <整盘>` → `mount <整盘>`（现状） |
| D4 | 默认模式：无分区、有 fs | 直接 `mount <整盘>`，不 mkfs |
| D5 | blkid 连续失败 | 5 次 blkid、0 次 mkfs/mount；退出码 1；输出含“因 blkid 失败跳过” |
| D6 | blkid 前 2 次失败后成功 | 第 3 次成功后按结果继续，不判失败 |
| D7 | `--rebuild` | 序列 `umount?→mklabel→mkpart→partprobe→(udevadm)→mkfs.ext4 -m 0→mount <分区>` |
| D8 | `--rebuild` + NVMe | 分区解析为 `/dev/nvme0n1p1`，不盲拼 |
| D9 | `--rebuild` + umount 失败 | 跳过该盘，不出现 parted/mkfs，其他盘继续，退出码 1 |
| D10 | 系统盘 | 任何模式都不出现在计划、零命令 |
| D11 | 编号不复用 | 预置 /mnt/HDD01 已挂载 sdb，新盘 sdc → HDD02 |
| D12 | 多分区盘默认模式 | 只挂载首分区；输出含“有 N 个分区，默认仅测第一个” |
| D13 | `--rebuild` 多分区盘 | 建 1 个 100% 分区，仅格式化该分区 |
| D14 | `--dry-run` | 输出完整计划、零写命令、`mount.log` 不存在 |
| D15 | 无 `--yes` 输入 N | 零命令、退出码 0 |
| D16 | blkid rc=2 且 stderr 非空（设备忙） | 5 次探测、0 次 mkfs/mount、退出 1 |
| D17 | 重建：同盘存在非 `/mnt/HDD*` 挂载点 | 整盘跳过、零 parted/umount/mkfs、退出 1 |
| D18 | df 未列出 `/mnt/HDD01`、lsblk 列出 | 新盘使用 HDD02（并集生效） |
| D19 | 重建后 lsblk 解析不到分区 | 跳过、无 mkfs、退出 1 |
| D20 | mount 失败 | 该盘失败、其他盘继续、退出 1 |
| D21 | `--dry-run` 含失败盘 | 输出 DRY RUN、退出 1、零写命令 |
| D22 | df `/` 为 `/dev/root`（无法可靠识别系统盘） | 非 dry-run 中止且零写命令；dry-run 仅告警 |
| D23 | 默认模式：子树 LVM 挂 `/data` | 跳过、零 mkfs/mount、显式提示 |
| D24 | `--rebuild`：子树 LVM/RAID 挂 `/data` | 零 parted/umount/mkfs、退出 1 |
| D25 | HDD 挂载 + 同盘 LVM 业务挂载混合 | 跳过该盘、其他盘继续、退出 1 |
| D26 | msdos 扩展分区 sdb1(0x5) + 逻辑分区 sdb5 | 挂载 sdb5，不对 sdb1 执行 mkfs/mount |
| D27 | 有分区表（PTTYPE=gpt）但无分区 | 跳过、零 mkfs、退出 1 |
| D28 | 仅扩展分区容器、无逻辑分区 | 跳过、零 mkfs、退出 1 |

### 8.2 stress-test.sh

| 编号 | 场景 | 期望 |
|---|---|---|
| S1 | 显式 `--dirs` 指向非挂载点 | 退出码 1，不启动 stress、不建结果目录 |
| S2 | 挂载点校验通过（假 findmnt） | 正常启动，`devices.txt` 含分区名与整盘名 |
| S3 | 假 dmesg 输出 `EXT4-fs error (device sdb1)` | `error.log` 出现 `dmesg io:`；review 结论“异常”即使 `state=OK` |
| S4 | sdb1 与 sdc1 同时报错，任务仅 sdb | 本任务 `error.log` 只含 sdb1 行；sdc1 行进 `error-unattributed.log` |
| S5 | 旧目录无 `devices.txt` | I/O 错误照常写 `error.log`（不过滤） |
| S6 | `sdb1` 与 `sdb10` 设备名 | 只归因 `sdb1`，不误配 `sdb10` |
| S7 | dmesg 不可用 | 不报错、不产生 `dmesg io:` |
| S8 | ENOSPC | 结论“异常（空间不足 ENOSPC，非磁盘故障）”，与退出码非 0 区分 |
| S9 | 系统盘任务 | 结果目录 `run-config.txt`/`summary.txt` 含覆盖边界说明；cwd 为 `/stresstest-hdd` |
| S10 | `status=OK` + 无错误 | 结论仍为“正常”（不误报） |

### 8.3 oneclick.sh

| 编号 | 场景 | 期望 |
|---|---|---|
| O1 | `all --rebuild` | 挂载命令含 `--rebuild`，`commands.txt` 落盘一致 |
| O2 | `all` 无 `--rebuild` | 命令不含 `--rebuild`，输出复用提示 |
| O3 | 菜单选 1 输入 y | 挂载命令含 `--rebuild` |
| O4 | 菜单选 2 输入 N | 不含 `--rebuild` |
| O5 | `sysdisk --rebuild` | 忽略并提示 |
| O6 | 挂载返回 1 但已有 /mnt/HDD* | hdd 模式继续启动数据盘任务，批次退出码 1 |
| O7 | hdd + 挂载返回 1 | summary 含“自动挂载: 存在跳过/失败盘”，退出码 1 |
| O8 | all + 挂载返回 1 | 同上（即使其他任务复盘正常） |

### 8.4 回归

- `.superpowers/sdd/2026-11-15-oneclick-stress/tests/run-all.sh`（76 项）
- `.superpowers/sdd/2026-11-15-spec-driven-stress-params/tests/run-all.sh`（135 项）
- `.superpowers/sdd/2026-11-15-oneclick-command-visibility/`（69 项）
- `.superpowers/sdd/2026-11-15-dirs-space-path/tests/run-all.sh`（91 项）

## 9. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 误清盘 | 默认不清盘；`--rebuild` 计划行标注“重建：清空分区表”，非 `--yes` 需 y；oneclick 需显式开关或菜单 y |
| blkid 语义歧义 | 三态契约（5.4）：有输出=有 fs；空输出+rc 0/2+空 stderr=无 fs；其余=失败重试后跳过 |
| parted 失败/分区未就绪 | 单盘失败不阻塞；lsblk 解析分区最多 5 次重试；`mount.log` 留证 |
| 归因失败（LVM/dm） | 未归因行进 `error-unattributed.log`，汇总提示，不污染结论、不静默丢弃 |
| 关键字误报 | 限定块设备/文件系统语境 + 设备边界匹配；OOM 规则不变 |
| 旧套件破坏 | 保留 blkid 调用形式、挂载成功文案、`monitor.csv` 列、`summary.txt` 既有字段 |
| hdd 模式因部分盘失败整体退出 | oneclick 改为“有挂载点则继续”，仅无盘时退出 |
| 固定 10G 遇小分区 | 计划提示可能 ENOSPC；结论单独标注空间不足 |

## 10. 文档与打包

- `README.md`：挂载说明补“默认复用/自动格式化无 fs 分区；`--rebuild` 会清空数据盘”；补 I/O 错误判定与 ENOSPC 说明。
- `operation-manual.md`：硬盘压测章节补 `--rebuild` 示例、多分区提示、blkid 跳过说明、系统盘覆盖边界。
- 用 `.superpowers/sdd/2026-11-15-spec-driven-stress-params/pack_zip.py` 重打 `offline-stress-pkg.zip`，核对工作区与包内 SHA256 一致。

## 11. 留给实现者的决定

- `probe_fs` 的临时文件与 stderr 处理细节；`udevadm` 不存在时的等待方式（`sleep 1`）。
- IO 正则的具体写法（只要覆盖 6.3 列出的类别）。
- `devices.txt` 内行序（分区名在前、整盘名在后）。
- 测试假件的组织方式与断言函数命名。
