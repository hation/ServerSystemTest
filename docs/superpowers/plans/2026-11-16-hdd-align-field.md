# 硬盘压测对齐现场口径 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让硬盘压测与现场流程一致：数据盘按分区挂载/格式化（显式 `--rebuild` 才清盘）、内核 I/O 错误可检测且按盘归因、系统盘口径明确，并保持既有行为兼容。

**Architecture:** 三个脚本各自收敛职责。`disk-mount.sh` 负责块设备规划与写操作（计划数组驱动，blkid 三态探测）；`stress-test.sh` 负责压测目录校验、设备归因文件、dmesg 增量检测与复盘结论；`oneclick.sh` 只做开关透传与菜单确认。三者通过文件（`mount.log`、`devices.txt`、`error.log`、`status.txt`、`run-config.txt`）传递证据，不改变既有结果目录结构。

**Tech Stack:** bash（Kylin V10 SP3，离线）；只使用系统自带 `lsblk`、`blkid`、`parted`、`partprobe`、`udevadm`、`mkfs.ext4`、`mount/umount`、`findmnt`、`df`、`dmesg`；测试用假命令注入（`PATH` 或接缝变量）。

**Spec:** `docs/superpowers/specs/2026-11-16-hdd-align-field-design.md`
**Requirements:** `docs/superpowers/notes/2026-11-16-hdd-stress-requirements.md`

## Global Constraints

- 仅 bash + 系统自带命令；不引入新依赖，不写 `/etc/fstab`。
- 默认行为**不清盘**：只有 `--rebuild`（或 oneclick 菜单输入 y）才重建分区表。
- 系统盘在任何模式、任何脚本中都不得分区/格式化/挂载。
- 既有 CLI 参数、结果目录名、`monitor.csv` 列、`review` 既有字段、既有输出文案（如 `已挂载 <盘> → /mnt/HDDxx`）不得破坏。
- `blkid` 调用形式固定 `$BLKID_BIN -s TYPE -o value <dev>`（既有测试假件依赖参数位置）。
- 所有新增输出、注释、文档使用中文。
- **不执行 git commit**；每个任务以对应测试全绿为完成判据。
- SDD 控制者把任务完成记录写入 `.superpowers/sdd/2026-11-16-hdd-align-field/progress.md`。
- 旧套件必须全绿：`2026-11-15-oneclick-stress`（76）、`2026-11-15-spec-driven-stress-params`（135）、`2026-11-15-oneclick-command-visibility`（69）、`2026-11-15-dirs-space-path`（91）。

## Review Focus

- 默认模式误格式化：无 `--rebuild` 且分区/整盘已确认有 fs 时不得出现 `mkfs`（Task 1 D1/D4）。
- blkid 失败仍格式化：必须 5 次探测后跳过、0 次 `mkfs`、退出码 1（Task 1 D5）。
- 重建挂错设备：`mount` 的必须是解析出的分区（NVMe 为 `p1`），不是整盘（Task 1 D7/D8）。
- 编号覆盖：已有 `/mnt/HDD01` 时新盘必须用 HDD02（Task 1 D11）。
- 系统盘误入流程：任何模式零命令（Task 1 D10）。
- I/O 错误漏判或跨盘污染：`status=OK` 仍判异常；sdb1 错误不得进 sdc 任务（Task 2 S3/S4/S10）。
- 归因边界：`sdb1` 不得命中 `sdb10`（Task 2 S6）。
- 挂载失败仍压测：显式 `--dirs` 非挂载点必须拒绝（Task 2 S1）。
- 部分盘失败导致整体不测：oneclick hdd 模式有盘则继续（Task 3 O6）。

---

### Task 1: disk-mount.sh 分区/格式化/探测/编号/重建

**Files:**
- Modify: `offline-stress-pkg/disk-mount.sh`
- Create: `.superpowers/sdd/2026-11-16-hdd-align-field/tests/lib.sh`
- Create: `.superpowers/sdd/2026-11-16-hdd-align-field/tests/t1_disk_plan.sh`
- Create: `.superpowers/sdd/2026-11-16-hdd-align-field/tests/t2_disk_rebuild.sh`
- Create: `.superpowers/sdd/2026-11-16-hdd-align-field/tests/run-all.sh`

**Interfaces:**
- Consumes: 既有 `collect_non_sys_disks`、`disk_lines`、`disk_is_mounted`、`disk_fpart`、`is_sys_disk_or_part`、`run_log`、`now`。
- Produces（Task 3 依赖 `--rebuild` 语义）：
  - CLI：`mount [--disks ...] [--yes] [--rebuild] [--dry-run]`
  - 接缝变量：`PARTED_BIN`、`PARTPROBE_BIN`、`UDEVADM_BIN`、`MKFS_BIN`、`MOUNT_BIN`、`UMOUNT_BIN`、`DF_BIN`（默认同名系统命令）
  - 函数：`probe_fs <dev>`（0=有 fs 且输出类型 / 1=无 fs / 2=探测失败）、`probe_fs_retry <dev>`（最多 5 次，间隔 1s）、`resolve_part <disk>`（lsblk 解析首分区，最多 5 次）
  - `devices.txt` 不在此任务生成（Task 2）

- [ ] **Step 1: 复制测试骨架**

从 `.superpowers/sdd/2026-11-15-oneclick-stress/tests/lib.sh` 复制到新目录，保留全部断言函数；`run_dm` 增加接缝透传：

```bash
run_dm() {
    local outf="$1"; shift
    PATH="$FAKE_BIN:$PATH" \
    SKIP_ROOT_CHECK=1 \
    MOUNT_LOG="$ROOT/mount.log" \
    LSBLK_BIN=lsblk BLKID_BIN=blkid \
    PARTED_BIN=parted PARTPROBE_BIN=partprobe UDEVADM_BIN=udevadm \
    MKFS_BIN=mkfs.ext4 MOUNT_BIN=mount UMOUNT_BIN=umount DF_BIN=df \
    bash "$DM_SH" "$@" > "$outf" 2>&1 < /dev/null
    LAST_RC=$?
    return 0
}
```

新增断言：`check_cmds`（`$ROOT/cmds.txt` 逐行 `grep -Fxq`）、`check_cmd_count <text> <n>`、`check_no_cmds`（文件不存在或为空）。

- [ ] **Step 2: 写失败用例（D1~D15）**

`t1_disk_plan.sh` 覆盖默认模式与编号（D1~D6、D10~D12、D14~D16、D18、D22、D23）；`t2_disk_rebuild.sh` 覆盖 `--rebuild`（D7~D9、D13、D17、D19~D21、D24、D25）。评审追加项：系统盘识别 fail-closed（D22）、子树 LVM/RAID 业务挂载保护（D17/D23/D24/D25）、编号并集（D18）。假件约定：

- 假 `lsblk` 支持三种形态：`-o NAME,SIZE,TYPE,MOUNTPOINT -l`（表格行）、`-no TYPE <dev>`、`-no pkname <dev>`、`-ln -o NAME,TYPE <dev>`（重建后分区解析）。
- 假 `blkid` 用 `$FAKE_BLKBASE` 目录记录调用次数：每次追加一行设备名；按 `$FAKE_BLK_PLAN`（如 `fail fail ext4`）返回对应结果；无文件系统时输出空并 `exit 0`（或 `exit 2`，分开用例）。
- 假 `parted`/`partprobe`/`mkfs.ext4`/`mount`/`umount`/`udevadm` 一律把 `命令 参数...` 追加到 `$ROOT/cmds.txt` 并 `exit 0`（失败用例按需 `exit 1`）。
- 假 `df` 输出表头 + `/dev/sda1 ... /`，编号用例额外输出已挂载 `/mnt/HDD01`。

关键断言示例：

```bash
CASE="D5 blkid 连续失败"
setup_case
printf 'fail fail fail fail fail\n' > "$ROOT/blk.plan"
run_dm "$OUTF" mount --disks sdb --yes
check_rc 1 '存在跳过盘应退出 1'
[ "$(wc -l < "$ROOT/blk.calls")" -eq 5 ] && _pass 'blkid 调用 5 次' || _fail 'blkid 调用次数不符'
check_out '因 blkid 失败跳过：sdb' '应列出跳过盘'
! grep -q 'mkfs' "$ROOT/cmds.txt" 2>/dev/null && _pass '不得格式化' || _fail '失败盘被格式化'
```

- [ ] **Step 3: 改造数据模型与编号**

- `disk_lines` 输出追加首分区容量；数组增加 `DISK_FPARTSZ`。
- 新增 `used_mount_numbers`（`$DF_BIN -P` 中 `^/mnt/HDD[0-9]+$` 的数字）。
- 新增计划数组 `PLAN_DISK/PLAN_MNT/PLAN_ACT/PLAN_REASON`，计划与执行逐项对应；不再在打印和执行两处各自递增编号。

- [ ] **Step 4: 实现探测与默认模式**

- `probe_fs` 按设计 5.4 三态实现（stdout 非空=0；空+rc 0/2+空 stderr=1；其余=2）。
- `probe_fs_retry` 最多 5 次、`sleep 1`，探测失败时先 `udevadm settle`（存在则调用，不存在跳过）。
- 默认模式按 5.5 决策树生成 `PLAN_ACT`；多分区盘追加提示；首分区容量不足 10G 追加提示。
- 执行段按 `PLAN_ACT` 执行，跳过盘记 `PLAN_REASON`，结束后打印跳过/失败汇总并 `exit 1`。

- [ ] **Step 5: 实现 `--rebuild` 与 `--dry-run`**

- 解析 `--rebuild`、`--dry-run`（后者置 `DRY_RUN=1`）。
- 重建步骤严格按设计 5.6；`resolve_part` 用 `lsblk -ln -o NAME,TYPE /dev/<disk>` 取第一个 `part`。
- `umount` 仅当挂载点在 `/mnt/HDD*`；失败跳过该盘。
- 所有命令经 `run_log`；每盘分配后写 `assign:` 日志。
- `DRY_RUN=1` 时命令序列为空、不创建 `mount.log`。

- [ ] **Step 6: 跑测试并修正**

```bash
bash .superpowers/sdd/2026-11-16-hdd-align-field/tests/t1_disk_plan.sh
bash .superpowers/sdd/2026-11-16-hdd-align-field/tests/t2_disk_rebuild.sh
```

预期全 PASS；再跑旧套件 `2026-11-15-oneclick-stress/tests/t1_disk_yes.sh` 确认 T1a `已挂载 sdb → /mnt/HDD01` 文案与退出码不变。

**Acceptance:** D1~D15 全 PASS；`t1_disk_yes.sh` 全 PASS。

---

### Task 2: stress-test.sh 归因与判定

**Files:**
- Modify: `offline-stress-pkg/stress-test.sh`
- Create: `.superpowers/sdd/2026-11-16-hdd-align-field/tests/t3_start_guard.sh`
- Create: `.superpowers/sdd/2026-11-16-hdd-align-field/tests/t4_io_detect.sh`

**Interfaces:**
- Consumes: 既有 `cmd_start` 目录校验、`cmd_monitor_loop` dmesg 段、`write_status`、`cmd_review`。
- Produces:
  - 接缝 `FINDMNT_BIN`（默认 `findmnt`）
  - 结果目录新增 `devices.txt`（每行一个设备名）、`error-unattributed.log`
  - `error.log` 新增行格式：`[时间] dmesg io: <原始行>`
  - `status.txt` 新增 `io=yes|no`
  - `run-config.txt` 在 `--sysdisk` 时新增 `压测对象:` / `覆盖边界:` 两行

- [ ] **Step 1: 写失败用例（S1~S10）**

沿用 Task 1 的 `lib.sh`（新增 `run_start`/`run_monitor`：注入 `ROOT` 为 `STRESS_TEST_ROOT`、`FINDMNT_BIN`、`DMESG_BIN`、`DF_BIN`、`MONITOR_INTERVAL=1`、假 `stress`）。

- S1：`--dirs $ROOT/plain`（假 findmnt 输出空）→ 退出码 1，`check_no_type_dir hdd`。
- S2：假 findmnt 按目录返回 `/dev/sdb1` → `devices.txt` 含 `sdb1` 与 `sdb`。
- S3：假 dmesg 首次输出 0 行、之后输出 `EXT4-fs error (device sdb1): ...` → 等 `error.log` 出现 `dmesg io:`；再手工写 `status.txt`（`state=OK`）后 `review --dir`，断言 `结论: 异常`。
- S4：设备 `sdb1` 任务、dmesg 同时含 sdb1/sdc1 错误 → `error.log` 仅 sdb1；`error-unattributed.log` 含 sdc1。
- S5：删除 `devices.txt` 后重放 → `error.log` 含 `dmesg io:`（不过滤）。
- S6：dmesg 含 `sdb10` 错误、设备为 `sdb1` → 不进 `error.log`。
- S7：`DMESG_BIN` 指向失败脚本 → 无 `dmesg io:`、退出正常。
- S8：`error-HDD01.log` 写 `No space left on device`、`state=OK` → `结论: 异常（空间不足 ENOSPC，非磁盘故障）`。
- S9：`start hdd --sysdisk-only`（假 df 可用空间充足）→ `run-config.txt`、`summary.txt` 含 `根文件系统压测` 与 `/boot`；假 stress 记录 cwd，断言 `/stresstest-hdd`。
- S10：正常结束（`state=OK`、无错误）→ `结论: 正常`。

- [ ] **Step 2: 挂载点校验（FR-3）**

- 文件头新增 `FINDMNT_BIN="${FINDMNT_BIN:-findmnt}"`。
- hdd/combo 目录校验统一走 `findmnt`，显式 `--dirs` 也校验；错误文案沿用现有行并补充显式目录说明。

- [ ] **Step 3: devices.txt（FR-6）**

- 新增 `dev_of_path`、`whole_disk_of`、`write_devices_file`。
- `cmd_start` 在 `run-config.txt` 之后、启动 stress 之前写 `$dir/devices.txt`（去重保序；解析失败保持空文件）。
- 系统盘归因用 `--target /`。

- [ ] **Step 4: dmesg I/O 检测（FR-5）**

- 拆 `dmesg_io_re` 与 `dmesg_oom_re` 常量。
- 增量循环逐行判定：先 I/O（归因）后 OOM；未归因写 `error-unattributed.log`；`io_seen=1`。
- `write_status` 追加 `io=` 行。

- [ ] **Step 5: 结论优先级与 ENOSPC（FR-7/FR-10）**

- `cmd_review` 先算 `err_hit`、`enospc`，再按设计 6.4 顺序判定；删除 `state=OK` 短路。
- 异常段追加“前 3 条命中行”和“未归因 N 条”。
- `run-config.txt` 增加系统盘口径两行；`summary.txt` 回显。

- [ ] **Step 6: 跑测试与旧回归**

```bash
bash .superpowers/sdd/2026-11-16-hdd-align-field/tests/t3_start_guard.sh
bash .superpowers/sdd/2026-11-16-hdd-align-field/tests/t4_io_detect.sh
bash .superpowers/sdd/2026-11-15-spec-driven-stress-params/tests/run-all.sh
```

**Acceptance:** S1~S10 全 PASS；135 项旧套件全 PASS。

---

### Task 3: oneclick.sh 透传与确认

**Files:**
- Modify: `offline-stress-pkg/oneclick.sh`
- Create: `.superpowers/sdd/2026-11-16-hdd-align-field/tests/t5_oneclick_rebuild.sh`

**Interfaces:**
- Consumes: Task 1 的 `disk-mount.sh mount ... --rebuild`；既有 `show_run`、`do_mount`、`write_plan`、`run_mode`、`menu_loop`。
- Produces: 全局 `REBUILD=0|1`；`do_mount` 组装 argv 时按 `REBUILD` 追加 `--rebuild`。

- [ ] **Step 1: 写失败用例（O1~O6）**

沿用 `2026-11-15-oneclick-stress/tests/lib.sh` 的假件风格（假 `stress-test.sh` 记录 argv、假 `disk-mount.sh` 记录 `$*` 并 `exit 0`、假 `df`）。

- O1：`run_oc all --rebuild` → `commands.txt` 含 `disk-mount.sh mount --disks all --yes --rebuild`。
- O2：`run_oc all` → 挂载命令不含 `--rebuild`，输出含 `未指定 --rebuild`。
- O3：`printf '1\ny\n' | run_oc`（菜单）→ 挂载命令含 `--rebuild`。
- O4：`printf '2\nn\n' | run_oc` → 不含 `--rebuild`。
- O5：`run_oc sysdisk --rebuild` → 输出提示“仅对 all/hdd 生效”，无挂载命令。
- O6：假 `disk-mount.sh` 退 1、假 `df` 给出一块 `/mnt/HDD01` → `hdd` 模式仍启动 HDD01 任务，退出码按复盘结果。

- [ ] **Step 2: 实现**

- 头部 `REBUILD=0`；参数解析支持 `--rebuild`；`usage` 补说明。
- `do_mount`：`argv=(bash "$DM" mount --disks all --yes)`，`REBUILD=1` 时 `argv+=(--rebuild)`。
- `run_mode` 对 `all|hdd`：未指定时输出复用提示；`sysdisk|cpu|mem` 指定时提示忽略并置 0。
- 菜单 1/2：询问 `是否重新分区并格式化数据盘？(y/N)`，`y` 置 1，其余 0；询问在读菜单选择之后、`run_mode` 之前只做一次。
- `write_plan` 挂载返回非 0：`hdd` 模式先 `collect_hdd_dirs`，为空才 `die`，否则警告继续。

- [ ] **Step 3: 跑测试与旧回归**

```bash
bash .superpowers/sdd/2026-11-16-hdd-align-field/tests/t5_oneclick_rebuild.sh
bash .superpowers/sdd/2026-11-15-oneclick-stress/tests/run-all.sh
bash .superpowers/sdd/2026-11-15-oneclick-command-visibility/tests/run-all.sh
bash .superpowers/sdd/2026-11-15-dirs-space-path/tests/run-all.sh
```

**Acceptance:** O1~O6 全 PASS；76 项、69 项、91 项旧套件全 PASS。

---

### Task 4: 文档、打包与全量回归

**Files:**
- Modify: `offline-stress-pkg/README.md`
- Modify: `offline-stress-pkg/operation-manual.md`
- Regenerate: `offline-stress-pkg.zip`

**Interfaces:**
- Consumes: Task 1/2/3 的最终行为。
- Produces: 文档口径与包内脚本一致；核对工作区与 zip 内脚本 SHA256。

- [ ] **Step 1: 更新 README**

- 挂载小节：默认复用/自动格式化无 fs 分区/多分区只测首分区提示；`--rebuild` 会清空整盘分区表；`--dry-run`。
- 判定小节：内核 I/O 错误即异常；ENOSPC 单独标注；系统盘=根文件系统压测及覆盖边界。

- [ ] **Step 2: 更新操作手册**

- 硬盘压测章节给出三种示例：默认复用、显式 `--rebuild`、`--dry-run` 预演。
- 写明 blkid 5 次重试失败跳过策略、部分盘跳过时退出码 1、oneclick 菜单确认默认 N。

- [ ] **Step 3: 重打包并校验**

```bash
python .superpowers/sdd/2026-11-15-spec-driven-stress-params/pack_zip.py
```

- 对比工作区与 zip 内 `disk-mount.sh`、`stress-test.sh`、`oneclick.sh` 的 SHA256 一致。

- [ ] **Step 4: 全量回归**

依次运行四套旧测试 + 新测试目录 `run-all.sh`，全部 ALL PASS 后记录到 `progress.md`。

**Acceptance:** 四套旧测试 + 新套件全 PASS；zip SHA256 一致；README/手册与实现一致。
