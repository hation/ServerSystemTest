# diskwipe-iso 真机问题修复（乱码 + 系统盘未清除） Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复 diskwipe-iso 真机两个问题：屏幕全部用户可见行 ASCII 化（IPMI KVM/Linux console 无中文字体乱码）、系统盘未清除的防御性加固（白名单扩展 + partprobe），出 v1.2.0。

**Architecture:** menu.sh/wipe.sh 所有用户可见输出改英文（中文仅代码注释）；lib.sh 白名单扩展（sd 两位字母、nvme/mmcblk 多位数字）并在 `wipefs -a` 成功后立即 partprobe（新增 PARTPROBE_BIN 接缝）；build-lib.sh 拷贝 partprobe；VERSION → v1.2.0 重打包。全部保持 POSIX/ash。

**Tech Stack:** bash（POSIX/ash）、busybox、util-linux（wipefs/partprobe/lsblk）、假件注入测试

**Spec:** [2026-11-21-diskwipe-iso-field-fix-design.md](../specs/2026-11-21-diskwipe-iso-field-fix-design.md)

## Global Constraints

- 全部 src 脚本 POSIX/ash 兼容（initramfs 只有 busybox ash）；LF 行尾。
- 测试绝不触碰本机真实块设备（假件经接缝变量注入）。
- **屏幕全部用户可见行 ASCII（无 CJK）**：menu.sh 与 wipe.sh 的标题/表头/类型标注/提示/确认/每盘结果（含失败原因）/警告/反馈行全英文；中文仅代码注释。
- 类型标注：`SYS`（系统盘）/ `DATA`（数据盘）/ `UNK`（未知）。
- 每盘结果：`OK /dev/<dev> reset to uninitialized` / `FAIL /dev/<dev>: <english reason>`（原因：umount failed / wipefs -a failed / wipefs -n failed / signatures remain / not whitelisted）。
- 白名单扩展：`sd[a-z]`+`sd[a-z][a-z]`、`nvme[0-9][0-9]*n[0-9][0-9]*`、`mmcblk[0-9][0-9]*`；仍排除 `TRAN=usb` 与 `sr*`/`loop*`/`ram*`。
- partprobe：`wipefs -a` 成功后**立即**执行（无论验证结果）；失败仅 `WARN:` 提示、不影响该盘结论；新增接缝 `PARTPROBE_BIN="${PARTPROBE_BIN:-partprobe}"`。
- build-lib.sh 拷贝工具清单补 `partprobe`（util-linux 同源，ldd 依赖收集）。
- 版本 v1.0.0 → **v1.2.0**（保留 BOM 布局）；重新 build 出 iso；qemu 冒烟（横幅 v1.2.0 + 菜单 ASCII + 虚拟盘 OK 输出）。
- 既有交互契约（默认全选/排除/YES/0 退出）不变；测试断言同步英文文案。

## Review Focus

- **漏 ASCII 行**：某条用户可见输出仍含中文 → 乱码残留（Task 1 N1 全输出行 grep 校验）。
- **白名单误伤**：扩展后把 `sraa`/`loop1` 等误纳入 → 仍须硬排除 sr*/loop*/ram*（Task 1 N6）。
- **partprobe 顺序**：必须在 wipefs -a 成功之后、验证之前/之后皆可（失败仅警告）→ 断言调用时机与 WARN 文案（Task 1 N4）。
- **结果可读性**：失败原因必须英文可读（重测定位系统盘未清的证据）→ N3 断言失败行含英文 reason。
- **测试断言同步**：既有 t1-t4 中文文案断言全部改为英文期望（回归门，Task 1）。

---

### Task 1: src 脚本 ASCII 化 + 白名单扩展 + partprobe + 测试

**Files:**
- Modify: `diskwipe-iso/src/menu.sh`（全部用户可见行英文）
- Modify: `diskwipe-iso/src/wipe.sh`（结果行 `OK`/`FAIL` + 英文 reason）
- Modify: `diskwipe-iso/src/lib.sh`（白名单扩展；`PARTPROBE_BIN` 接缝；`dw_wipe_disk` 加 partprobe；`dw_is_system_disk` 注释同步）
- Modify: `diskwipe-iso/tests/t1_wipe.sh` / `t2_menu.sh` / `t3_init.sh` / `t4_log.sh`（文案断言英文同步；新增 partprobe/白名单假件）
- Create: `diskwipe-iso/tests/t5_ascii.sh`（N1/N2/N3/N4/N5/N6）

**Interfaces:**
- Consumes: 既有接缝（LSBLK_BIN/BLKID_BIN/WIPEFS_BIN/UMOUNT_BIN）+ 新增 `PARTPROBE_BIN`；`dw_enum_disks`/`dw_wipe_disk`/`dw_is_system_disk`
- Produces: 英文交互文案；`dw_wipe_disk` 在 wipefs -a 后调用 partprobe；白名单扩展后的 `dw_dev_ok`/`dw_enum_disks`

- [ ] **Step 1: 写 t5_ascii.sh 用例（N1-N6）并跑 fail 阶段**

  | 编号 | 断言 |
  |---|---|
  | N1 | 对 menu.sh/wipe.sh 的全部 stdout 输出行做 CJK 校验：跑典型流程（列盘→回车→YES→清除→0 退出）采集输出，`grep -P '[^\x00-\x7F]'` 无命中（含标题/表头/类型/结果/警告/反馈行） |
  | N2 | 系统盘（PARTTYPENAME=EFI System）标 `SYS`；数据盘标 `DATA`；未知标 `UNK` |
  | N3 | 成功输出含 `OK /dev/<dev> reset to uninitialized`；失败输出含 `FAIL /dev/<dev>: ` 与英文 reason（如 `wipefs -a failed`） |
  | N4 | `wipefs -a` 成功后 cmds.txt 含 `partprobe /dev/<dev>`（验证结果失败时也调用）；partprobe 假件返回 1 → 输出 `WARN:` 但该盘结论不变 |
  | N5 | `PARTPROBE_BIN` 指向假件时记录调用；生产默认 `partprobe` |
  | N6 | `dw_dev_ok`/`dw_enum_disks`：`sdab`、`nvme0n10`、`mmcblk10`、`sdaa` 通过；`sr0`、`loop0`、TRAN=usb 仍排除 |

  运行 `bash diskwipe-iso/tests/run-all.sh`，预期 t5 FAIL（ASCII 校验/新行为未实现）。

- [ ] **Step 2: lib.sh — 白名单扩展 + PARTPROBE_BIN 接缝 + dw_wipe_disk 加 partprobe**

  按 Global Constraints 的白名单正则与 partprobe 时机实现；`dw_is_system_disk` 注释同步（SYS/DATA/UNK 语义不变，仅输出映射到 menu）。

- [ ] **Step 3: menu.sh / wipe.sh — 全部用户可见行英文化**

  标题 `DiskWipe Tool v<ver> — Reset disks to uninitialized`；表头 `# Device Size Model/Status Type`；类型 `SYS/DATA/UNK`；提示 `Default: all selected. Enter exclusions (e.g. 1,2; empty = all)`；确认 `Will wipe the following N disks (irreversible!). Type YES to confirm:`；退出 `0 = exit (power off or reboot after done)`；反馈行（仅启动介质/已取消/未选择/输入结束）全英文；wipe.sh 结果 `OK`/`FAIL`+英文 reason。中文仅代码注释。

- [ ] **Step 4: 既有 t1-t4 断言英文同步 + 跑 t5 全绿 + 全量回归**

  `bash diskwipe-iso/tests/run-all.sh`（Git Bash）→ t1-t5 全 PASS；`bash --posix -n diskwipe-iso/src/*.sh diskwipe-iso/src/init` 0 错误。

- [ ] **Step 5: Commit**

  ```bash
  git add diskwipe-iso/src diskwipe-iso/tests
  git commit -m "fix(diskwipe-iso): 屏幕输出 ASCII 化（无中文字体终端可读）+ 白名单扩展 + wipefs 后 partprobe 刷新分区视图"
  ```

---

### Task 2: 构建（partprobe 拷入 + v1.2.0 重打包 + qemu 冒烟）+ README

**Files:**
- Modify: `diskwipe-iso/build-lib.sh`（拷贝工具清单补 partprobe）
- Modify: `diskwipe-iso/VERSION`（1.1.0 → 1.2.0）
- Modify: `diskwipe-iso/README.md`（交互示意改英文；乱码修复说明；partprobe 说明）

**Interfaces:**
- Consumes: Task 1 的英文文案与 partprobe 接缝（依赖 build 拷入 partprobe）
- Produces: `output/diskwipe-v1.2.0.iso`

- [ ] **Step 1: build-lib.sh 拷贝工具清单补 partprobe**

  在 util-linux 工具拷贝处加入 `partprobe`（与 wipefs/lsblk 同源，ldd 收集依赖）。

- [ ] **Step 2: VERSION 1.1.0 → 1.2.0**

  写 `1.2.0`（保留 BOM 布局）。

- [ ] **Step 3: 重新构建 + 校验 + qemu 冒烟**

  `bash diskwipe-iso/build.sh`（Git Bash）→ `output/diskwipe-v1.2.0.iso`；isoinfo 三关键文件 + initrd 内 `/diskwipe.version`=1.2.0 + dash -n 0 错误；**qemu 冒烟**（挂 1G virtio 盘 + 虚拟 U 盘）：横幅 `DiskWipe Tool v1.2.0`、菜单全英文（无乱码）、虚拟盘清除输出含 `OK /dev/vda reset to uninitialized`。

- [ ] **Step 4: README 更新**

  交互示意改英文；说明乱码已修复（IPMI KVM/无中文字体终端可读）；partprobe 行为说明；白名单扩展说明（支持 27+ 盘/多位数字）。交叉核对真实行为。

- [ ] **Step 5: 全量回归 + Commit**

  `bash diskwipe-iso/tests/run-all.sh` 全 PASS；
  ```bash
  git add diskwipe-iso/build-lib.sh diskwipe-iso/VERSION diskwipe-iso/README.md
  git commit -m "release(diskwipe-iso): v1.2.0 真机问题修复（ASCII 化 + partprobe + 白名单扩展）重打包"
  ```

---

## 交付后重测指引（用户执行，README 同步）

用 v1.2.0 iso → IPMI KVM 进 → 确认列表全英文可读（含系统盘）→ 全选 → YES → 逐盘看 `OK`/`FAIL` → 重启后用 FirPE 复查系统盘与业务盘。若系统盘仍未清，记录列表与每盘结果反馈。
