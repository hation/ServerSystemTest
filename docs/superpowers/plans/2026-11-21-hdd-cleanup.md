# 压测后数据盘自动清理 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 压测结束后自动清理数据盘（umount → `wipefs -a` 整盘 → partprobe 回空白盘），并提供 `disk-mount.sh clean` 一键清空全部非系统盘、非U盘。

**Architecture:** 在 disk-mount.sh 入口新增 `clean` 子命令（detect/commands lib 各加函数，保持入口+lib 拆分结构）；oneclick.sh 在批次复盘后调用 `clean --disks <本批盘> --yes` 自动清理，新增 `--no-cleanup` 开关与菜单项 10。新增 sdd 测试目录覆盖 clean 与自动清理。

**Tech Stack:** bash（Kylin V10 SP3）、util-linux（wipefs/partprobe/lsblk/findmnt）、离线测试假件（接缝变量注入）

**Spec:** [2026-11-21-hdd-cleanup-design.md](../specs/2026-11-21-hdd-cleanup-design.md)

## Global Constraints

- 系统盘 fail-closed：`SYS_ID_OK=0`（识别不可靠）且非 dry-run → clean 中止退出 1，零写操作。
- U 盘（`lsblk -P -o NAME,TRAN` 中 `TRAN=usb`）一律排除；`--disks` 显式指定 U 盘/系统盘/不存在盘 → 拒绝退出 1。
- 清理粒度固定：umount 全部子树挂载点 → `wipefs -a <整盘>` → partprobe；任一步失败仅跳过该盘、其他盘继续、退出码 1。
- 空白盘判定用 `wipefs -n`（输出为空即空白）；`wipefs -n` 不可用/失败 → fail-safe 照清。
- 一键命令（无 `--disks` 时）范围 = 全部非系统盘、非U盘，**含业务挂载点盘**（用户显式决策），业务挂载点须在计划中醒目标注；默认 y/N 确认，`--yes` 跳过。
- 自动清理范围严格限定 `$BATCH/cleanup-devices.txt` 记录的本批盘（父整盘名）；清理时点预检：盘已不存在或出现非 `/mnt/HDD*` 挂载点 → 跳过该盘并在 summary 标注，不整批失败。
- 自动清理默认开启，`--no-cleanup` 关闭；命令经 `show_run` 展示并落 commands.txt（`--quiet` 不丢落盘）。
- 清理失败**不改变** review 结论与批次退出码；summary 标注并提示手动 `bash disk-mount.sh clean`。
- 只清数据盘；系统盘与 `/stresstest-hdd` 压测文件不清理。
- 脚本保持 LF 行尾；函数体在 lib、入口只做分发（既有拆分结构）。
- 打包：VERSION 1.1.3 → 1.2.0，产出 `offline-stress-pkg.zip` 与 `offline-stress-pkg-v1.2.0.zip`（内容一致），旧 zip 保留。

## Review Focus

- 分区名 vs 整盘名：默认模式挂载首分区（`/dev/sdb1`），若记录/接收的是分区名，`clean --disks` 会误判"盘不存在" → 全链路 PKNAME 归一（Task 1 C13、Task 2 O1 断言）。
- 系统盘识别不可靠仍执行写操作 → 非 dry-run 中止零命令（Task 1 C5）。
- U 盘被误清 → TRAN=usb 排除（Task 1 C6）。
- 自动清理误清本批之外的盘/业务盘 → 范围限定 cleanup-devices.txt + 清理时点预检（Task 2 O1/O6/O7）。
- 空白盘/已卸载盘上 wipefs 报错被误判失败 → `wipefs -n` 判定 + fail-safe 照清（Task 1 C14/C15）。

---

### Task 1: disk-mount.sh `clean` 子命令

**Files:**
- Modify: `offline-stress-pkg/disk-mount.sh`（变量区加 `WIPEFS_BIN="${WIPEFS_BIN:-wipefs}"`；分发 case 加 `clean) cmd_clean "$@" ;;`；头部用法注释补 clean）
- Modify: `offline-stress-pkg/disk-mount-lib-detect.sh`（新增 `disk_is_usb`、`disk_parent`）
- Modify: `offline-stress-pkg/disk-mount-lib-commands.sh`（新增 `cmd_clean`）
- Create: `.superpowers/sdd/2026-11-21-hdd-cleanup/tests/lib.sh`
- Create: `.superpowers/sdd/2026-11-21-hdd-cleanup/tests/t1_clean.sh`
- Create: `.superpowers/sdd/2026-11-21-hdd-cleanup/tests/run-all.sh`

**Interfaces:**
- Consumes: 既有 `collect_non_sys_disks`（枚举非系统盘数组 DISK_NAMES…）、`disk_mountpoints <name>`（子树挂载点）、`is_sys_disk_or_part`、`SYS_ID_OK`、`root_check`、`run_log`、`DRY_RUN`
- Produces:
  - `disk_is_usb <name>` → 0（USB）/1（非 USB），按 `lsblk -P -o NAME,TRAN` 解析
  - `disk_parent <dev-or-part>` → 父整盘名（如 `sdb1`→`sdb`、`nvme0n1p1`→`nvme0n1`，经 `lsblk -no PKNAME`）
  - `cmd_clean <args>`：`--disks sdb,sdc` / `--yes` / `--dry-run`；退出码 0=成功/取消/无需操作，1=失败
  - CLI 契约：`bash disk-mount.sh clean [--disks 盘列表] [--yes] [--dry-run]`

- [ ] **Step 1: 建测试骨架 lib.sh 与 t1_clean.sh（复制 hdd-align-field 的 lib.sh 并扩展假件）**

  复制 `.superpowers/sdd/2026-11-16-hdd-align-field/tests/lib.sh` 为 `.superpowers/sdd/2026-11-21-hdd-cleanup/tests/lib.sh`，扩展：
  - `fake_bin wipefs`：`wipefs -n <dev>` 按 `$ROOT/wipefs.sigs` 输出签名；`wipefs -a <dev>` 把 `wipefs -a <dev>` 追加到 `$ROOT/cmds.txt`；指定 `WIPEFS_ALWAYS_FAIL=1` 时 `-a` 返回非 0
  - lsblk 假件支持 `-P -o NAME,TRAN`（按 `$ROOT/lsblk.tran` 返回），供 `disk_is_usb`
  - 确保 `partprobe` 假件已记录到 cmds.txt

- [ ] **Step 2: 写 t1_clean.sh 用例 C1-C15 并跑通 fail 阶段**

  每个用例：`CASE=...; setup_tmp; install_fakes; 写 lsblk.table/lsblk.tran/wipefs.sigs/df.txt; run_dm "$OUTF" clean <args>; check_*; cleanup_case`。断言要点（具体值写进用例）：

  | 用例 | 场景 | 断言 |
  |---|---|---|
  | C1 | sdb/sdc 各挂 /mnt/HDD01、/mnt/HDD02（sda 系统盘），输 y | cmds.txt 含 `umount /mnt/HDD01`、`umount /mnt/HDD02`、`wipefs -a /dev/sdb`、`wipefs -a /dev/sdc`、`partprobe /dev/sdb`、`partprobe /dev/sdc`；不含 sda 任何命令；退出 0 |
  | C2 | 同 C1 加 `--dry-run` | cmds.txt 空、mount.log 不存在、输出含 `（DRY RUN，未执行）`、退出按计划判定 |
  | C3 | 同 C1 加 `--yes` | 输出不含"确认清空"；命令齐全 |
  | C4 | `--disks sdb` | cmds.txt 只含 sdb 相关，无 sdc |
  | C5 | df `/` 输出 `/dev/root`（SYS_ID_OK=0） | 非 dry-run：输出含中止原因、cmds.txt 空、退出 1；dry-run：仅告警 |
  | C6 | sde 的 TRAN=usb | 计划不含 sde，cmds.txt 无 sde |
  | C7 | sdd 无分区无挂载且 wipefs.sigs 空 | 计划显示"无需清理"，cmds.txt 无 sdd，退出 0 |
  | C8 | sdc 挂 /data（业务）+ /mnt/HDD02 | 计划列出 /data 并含"业务挂载点"标注；确认后 cmds.txt 含 `umount /data` 与 `wipefs -a /dev/sdc` |
  | C9 | umount /mnt/HDD01 失败（假 umount 返回非 0） | 输出含失败原因；无 `wipefs -a /dev/sdb`；sdc 正常清理；退出 1 |
  | C10 | `--disks sda` | 拒绝并退出 1，cmds.txt 空 |
  | C11 | `--disks sdz`（不存在） | 拒绝并退出 1 |
  | C12 | 仅 sda（系统盘） | 输出"无非系统盘、非U盘可清理"，退出 0 |
  | C13 | `--disks sdb1`（分区名） | 归一为 sdb，cmds.txt 只含 sdb 相关 |
  | C14 | wipefs 假件不可用（`WIPEFS_BIN` 指向不存在命令） | fail-safe：仍执行 `wipefs -a`（或该盘不被跳过） |
  | C15 | `wipefs -a` 失败（WIPEFS_ALWAYS_FAIL=1） | 该盘跳过、其他盘继续、退出 1 |

  运行 `bash run-all.sh`，预期 C1-C15 至少大部分 FAIL（命令不存在 `cmd_clean`/`disk_is_usb` 未定义）。

- [ ] **Step 3: 在 disk-mount-lib-detect.sh 实现 `disk_is_usb` 与 `disk_parent`**

  `disk_is_usb`：`lsblk -P -o NAME,TRAN` 解析该盘 TRAN==usb；解析失败视为非 USB（安全：宁可多清不误排，排除逻辑只认明确 usb）。
  `disk_parent`：`lsblk -ln -no PKNAME /dev/<name>` 取父盘；输出为空（无父盘，即整盘本身）则原样返回。

- [ ] **Step 4: 在 disk-mount-lib-commands.sh 实现 `cmd_clean`**

  流程：解析参数（--disks/--yes/--dry-run，非法即 usage 退出 1）→ `root_check` → `sys_disk_base` 已加载（detect 顶部调用）→ 校验 `SYS_ID_OK`（非 dry-run 且为 0 → 中止）→ 候选盘 = `--disks` 归一（`disk_parent`）后逐盘校验（系统盘→拒绝；U 盘→拒绝；不存在→拒绝）或枚举（`collect_non_sys_disks` + `disk_is_usb` 过滤）→ 每盘状态判定（`disk_mountpoints` 列表 + `$WIPEFS_BIN -n` 输出）→ 打印计划（业务挂载点标注）→ 非 `--yes` 时 y/N 确认 → 执行（逐盘：umount 循环 → `run_log $WIPEFS_BIN -a /dev/<name>` → `run_log $PARTPROBE_BIN`）→ 汇总失败盘 → 退出码。`DRY_RUN=1` 时只打印计划、不写 mount.log、末尾 `（DRY RUN，未执行）`。umount 失败/wipefs 失败只跳过该盘。

- [ ] **Step 5: 跑 t1_clean.sh 全绿**

  运行 `bash .superpowers/sdd/2026-11-21-hdd-cleanup/tests/run-all.sh`，预期全部 PASS、退出 0。

- [ ] **Step 6: 跑 hdd-align-field 回归（disk-mount 28 项）**

  运行 `bash .superpowers/sdd/2026-11-16-hdd-align-field/tests/run-all.sh`，预期全绿。

- [ ] **Step 7: Commit**

  ```bash
  git add offline-stress-pkg/disk-mount.sh offline-stress-pkg/disk-mount-lib-detect.sh offline-stress-pkg/disk-mount-lib-commands.sh .superpowers/sdd/2026-11-21-hdd-cleanup
  git commit -m "feat(offline-stress): disk-mount.sh 新增 clean 子命令（一键清空非系统盘、非U盘）"
  ```

---

### Task 2: oneclick 批次自动清理 + 菜单项 + `--no-cleanup`

**Files:**
- Modify: `offline-stress-pkg/oneclick.sh`（变量区 `CLEANUP=1`；参数解析 `--no-cleanup`；分发 case 加 `clean`；`menu_loop` 加项 10；`run_mode` case 加 clean）
- Modify: `offline-stress-pkg/oneclick-lib-basic.sh`（usage/菜单文案加项 10 与 --no-cleanup 说明；`write_env_file` 加 `CLEANUP=$CLEANUP`）
- Modify: `offline-stress-pkg/oneclick-lib-run.sh`（`write_plan` 记录 cleanup-devices.txt；`run_mode` 复盘后自动清理；`run_mode` clean 分支）
- Create: `.superpowers/sdd/2026-11-21-hdd-cleanup/tests/t2_oneclick_cleanup.sh`

**Interfaces:**
- Consumes: Task 1 的 `bash disk-mount.sh clean --disks <列表> --yes`；既有 `write_plan`/`run_review_all`/`collect_hdd_dirs`/`show_run`；`FINDMNT_BIN` 接缝（沿用 stress-lib 默认 findmnt）
- Produces:
  - `CLEANUP` 全局（默认 1）；`--no-cleanup` 置 0
  - `$BATCH/cleanup-devices.txt`：本批数据盘父整盘名（`findmnt -n -o SOURCE --target <dir>` → basename → `disk_parent` 归一），去重
  - `run_mode` 在 `run_review_all` 后执行自动清理并把结果追加进 summary.txt

- [ ] **Step 1: 写 t2_oneclick_cleanup.sh 用例 O1-O7 并跑 fail 阶段**

  参考 `.superpowers/sdd/2026-11-16-hdd-align-field/tests/t6_oneclick_rebuild.sh` 的 oneclick stub 模式（假 mount/stress/findmnt/wipefs + 短超时跑通批次）。断言：

  | 用例 | 场景 | 断言 |
  |---|---|---|
  | O1 | `oneclick.sh all`（1 块数据盘挂 /mnt/HDD01，sdb1） | commands.txt 含 `bash <DM> clean --disks sdb --yes`（父盘归一 sdb，非 sdb1）；summary.txt 含 `数据盘清理: 已清空` |
  | O2 | 加 `--no-cleanup` | 无 clean 命令；summary 含 `已跳过（--no-cleanup）` |
  | O3 | `oneclick.sh all --no-hdd` | 无 clean 命令；summary 含 `无数据盘` |
  | O4 | wipefs 假件 `-a` 返回非 0 | 各任务 review 结论不变；summary 含 `清理: 失败` 与 `bash disk-mount.sh clean` 提示；批次退出码与无清理时一致 |
  | O5 | `oneclick.sh clean` / 菜单项 10 | 最终调用 `disk-mount.sh clean`（交互确认路径，输出含待清理计划） |
  | O6 | cleanup 时盘已不存在（记录 sdb 但 findmnt 现为空） | summary 含 `已跳过 N 块（设备已不存在）`；clean 命令只含现存盘 |
  | O7 | cleanup 时盘出现非 /mnt/HDD* 挂载点 | 该盘跳过并标注；summary 提示手动命令 |

  运行 run-all.sh，预期 O1-O7 FAIL（`run_mode` 无清理逻辑）。

- [ ] **Step 2: oneclick.sh 加 `CLEANUP` 变量与 `--no-cleanup` 解析**

  变量区 `CLEANUP=1`；参数 case 加 `--no-cleanup) CLEANUP=0; shift`；usage 提示段补 `--no-cleanup  批次结束后不自动清空数据盘（默认自动清空本批数据盘）`。

- [ ] **Step 3: write_plan 记录 cleanup-devices.txt**

  在 all/full/hdd 分支（非 `NO_HDD=1`）枚举 `/mnt/HDD*` 目录写 plan 的同时：对每个目录 `findmnt -n -o SOURCE --target <dir>` 取设备 → basename → `disk_parent` 归一 → 去重写 `$BATCH/cleanup-devices.txt`（先 `: >` 清空）。目录未挂载（findmnt 失败）不记录。

- [ ] **Step 4: run_mode 自动清理（复盘后）**

  在 `run_mode` 中 `run_review_all` 与最终退出判定之间插入：`CLEANUP=1` 且 `mode ∈ all|full|hdd` 且 `NO_HDD=0` 且 cleanup-devices.txt 非空时：预检（过滤已不存在盘、过滤有非 /mnt/HDD* 挂载点盘，各自计数）→ 剩余非空则 `show_run bash $DM clean --disks <逗号列表> --yes` 并执行 → 结果追加到 summary.txt（成功/失败/跳过标注；失败时提示手动 `bash disk-mount.sh clean`）。不改变 review_rc 与最终退出码。`run_mode` 的 `clean` 分支：`exec bash $DM clean`（交互）。

- [ ] **Step 5: 菜单项 10 与 CLI clean 分发**

  `show_menu` 项 9 与 0 之间加 `10) 清空数据盘（全部非系统盘、非U盘；卸载并 wipefs 整盘，需 y 确认）`；`menu_loop` 加 `10) run_mode clean ;;` 并改提示 `请选择（0-10）`；main 分发 case 加 `clean`（`all|hdd|sysdisk|cpu|mem|full|clean`）与 `run_mode clean`。

- [ ] **Step 6: 跑 t2_oneclick_cleanup.sh 全绿**

  运行 `bash .superpowers/sdd/2026-11-21-hdd-cleanup/tests/run-all.sh`，预期 t1+t2 全部 PASS。

- [ ] **Step 7: oneclick 回归套件**

  运行：
  - `.superpowers/sdd/2026-11-15-oneclick-stress/tests/run-all.sh`（76 项）
  - `.superpowers/sdd/2026-11-15-oneclick-command-visibility/`（69 项）
  - `.superpowers/sdd/2026-11-16-hdd-align-field/tests/run-all.sh`
  预期全绿；命令可见性回归必须验证自动清理命令仍落 commands.txt。

- [ ] **Step 8: Commit**

  ```bash
  git add offline-stress-pkg/oneclick.sh offline-stress-pkg/oneclick-lib-basic.sh offline-stress-pkg/oneclick-lib-run.sh .superpowers/sdd/2026-11-21-hdd-cleanup
  git commit -m "feat(offline-stress): oneclick 批次结束自动清空数据盘（--no-cleanup 可关）+ 菜单项 10"
  ```

---

### Task 3: 文档同步（README / operation-manual / 命令执行逻辑）

**Files:**
- Modify: `offline-stress-pkg/README.md`
- Modify: `offline-stress-pkg/operation-manual.md`
- Modify: `docs/命令执行逻辑.md`

**Interfaces:**
- Consumes: Task 1/2 的实际 CLI（`disk-mount.sh clean`、`oneclick.sh --no-cleanup`、菜单项 10）

- [ ] **Step 1: README.md**

  挂载章节后补"压测后清理"小节：`disk-mount.sh clean` 用法（--disks/--yes/--dry-run）、语义（umount→wipefs -a 整盘→partprobe；不影响 SMART 通电数据）、`oneclick --no-cleanup`、菜单项 10。

- [ ] **Step 2: operation-manual.md**

  §3.4"测试完成后卸载"改为"测试完成后清理"：自动清理说明（默认开启/--no-cleanup/范围=本批盘）+ 一键清空命令与示例 + wipefs 语义与安全说明。

- [ ] **Step 3: docs/命令执行逻辑.md**

  补 `clean` 子命令与 oneclick 自动清理的执行逻辑段落；按函数所在 lib 更新行号引用（disk-mount-lib-commands.sh 的 cmd_clean、oneclick-lib-run.sh 的自动清理段）。

- [ ] **Step 4: Commit**

  ```bash
  git add offline-stress-pkg/README.md offline-stress-pkg/operation-manual.md docs/命令执行逻辑.md
  git commit -m "docs(offline-stress): 补压测后数据盘清理说明（clean/--no-cleanup/菜单项10）"
  ```

---

### Task 4: 版本号 v1.2.0 + 打包 + 整支回归

**Files:**
- Modify: `offline-stress-pkg/VERSION`（1.1.3 → 1.2.0）
- 产物：`offline-stress-pkg.zip`、`offline-stress-pkg-v1.2.0.zip`

**Interfaces:**
- Consumes: Task 1-3 全部改动；`.superpowers/sdd/2026-11-15-spec-driven-stress-params/pack_zip.py`

- [ ] **Step 1: 改 VERSION 并全量回归**

  `VERSION` 写 `1.2.0`（保留 UTF-8 BOM 原样）。跑全部回归套件：hdd-align-field、oneclick-stress(76)、spec-driven-stress-params(135)、oneclick-command-visibility(69)、dirs-space-path(91)、新 hdd-cleanup(t1+t2)。全部 PASS 才进入打包。

- [ ] **Step 2: 打双 zip 并核对内容一致**

  用 `pack_zip.py` 重打 `offline-stress-pkg.zip`（日常）与 `offline-stress-pkg-v1.2.0.zip`（留档）；比对两 zip 内文件 SHA256 一致；核对工作区文件与包内对应文件 SHA256 一致（VERSION=1.2.0）。旧 zip 保留。

- [ ] **Step 3: Commit**

  ```bash
  git add offline-stress-pkg/VERSION offline-stress-pkg.zip offline-stress-pkg-v1.2.0.zip
  git commit -m "release(offline-stress): v1.2.0 数据盘清理功能（clean/自动清理）打包留档"
  ```
