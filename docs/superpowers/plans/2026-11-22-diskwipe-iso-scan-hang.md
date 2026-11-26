# diskwipe-iso 列盘卡住修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复 v1.2.0 真机"列盘卡住"：列盘循环零外部 exec + 全部只读探测 timeout 3 兜底 + 枚举超时降级 + 进度/日志增强，出 v1.3.0。

**Architecture:** 批量类型探测 `dw_scan_system_disks`（1 次 lsblk + 1 次 blkid `-c /dev/null -o full`）+ 批量格式化 `dw_format_disk_lines`（1 次 awk），menu 列盘循环查表纯 shell 显示；新增 `TIMEOUT_BIN` 接缝包所有只读探测；枚举超时打印错误并重试一次。全部 POSIX/ash。

**Tech Stack:** bash（POSIX/ash）、busybox（timeout applet）、util-linux（lsblk/blkid）、假件注入测试

**Spec:** [2026-11-22-diskwipe-iso-scan-hang-design.md](../specs/2026-11-22-diskwipe-iso-scan-hang-design.md)

## Global Constraints

- 全部 src 脚本 POSIX/ash 兼容（initramfs 只有 busybox ash）；LF 行尾。
- 测试绝不触碰本机真实块设备（假件经接缝变量注入）。
- 屏幕全部用户可见行 ASCII（无 CJK），中文仅代码注释（沿用 v1.2.0 约束）。
- **列盘循环内零外部命令**（无 awk/lsblk/blkid/printf 外部版；纯 shell 字符串切分 + 预计算数据）。
- 批量探测：一次 lsblk + 一次 blkid（`-c /dev/null -o full` 带设备名输出）；探测口径与 `dw_is_system_disk` 一致（EFI 名含 EFI、MBR 0x80、ntfs、全未知→UNK）。
- **批量超时取舍**：timeout 杀整个进程 → 接受"批量超时 → 全部盘标 UNK"（类型仅提示不影响清除）。
- **timeout 覆盖全部只读探测**：dw_enum_disks、dw_scan_system_disks、dw_disk_mountpoints、init 的日志介质探测（dw_mount_log_media）；接缝 `TIMEOUT_BIN="${TIMEOUT_BIN:-timeout}"`，参数 `"$TIMEOUT_BIN" 3 <cmd>`。
- **清除操作（umount/wipefs/partprobe）不加 timeout**。
- **枚举超时降级**：`dw_enum_disks` 空/超时时 menu 打印 `ERROR: disk scan timed out or failed`，自动重试一次；仍失败打印错误并提示可安全重启（**不误判"仅启动介质"退出**）。
- 进度：枚举后打印 `Scanning disks... (please wait)`；枚举结果落日志（盘清单）。
- 版本 v1.2.0 → **v1.3.0**（保留 BOM 布局）；重新 build + qemu 冒烟（横幅 v1.3.0 + 列盘正常 + 虚拟盘 `OK /dev/vda`）；README 更新。
- 既有交互契约（默认全选/排除/YES/0 退出）不变；既有 t1-t5 断言保持 PASS。

## Review Focus

- **列盘循环残留外部命令**：某行仍启动 awk/lsblk/blkid → 卡住未根除（Task 1 H1 cmds.txt 断言）。
- **枚举超时误判"仅启动介质"**：枚举空 → 直接退出而非错误+重试（Task 1 H7）。
- **批量 blkid 格式**：`-o full` 假件形态与生产 util-linux 一致（带设备名），否则类型映射全断（Task 1 H2 假件形态）。
- **清除操作被误加 timeout**：破坏性操作半途中断 → 数据状态不确定（Task 1 H8 cmds.txt 断言清除调用无 timeout）。
- **timeout 覆盖不完整**：dw_disk_mountpoints/init 探测漏包 → 别处再卡（Task 1 H9）。

---

### Task 1: src 批量探测/格式化 + timeout 接缝 + menu 列盘零 exec + 枚举降级 + 进度日志

**Files:**
- Modify: `diskwipe-iso/src/lib.sh`（新增 `dw_scan_system_disks`/`dw_format_disk_lines`；`TIMEOUT_BIN` 接缝；`dw_enum_disks`/`dw_disk_mountpoints` 包 timeout；`dw_is_system_disk` 保留供查表口径）
- Modify: `diskwipe-iso/src/menu.sh`（列盘循环改查表零 exec；枚举超时降级；`Scanning disks...`；枚举结果落日志）
- Modify: `diskwipe-iso/src/init`（dw_mount_log_media 探测包 timeout）
- Modify: `diskwipe-iso/tests/t5_ascii.sh`（或新增 t6_scan.sh：H1-H9；既有断言同步）
- Create: `diskwipe-iso/tests/t6_scan.sh`（H1-H9）

**Interfaces:**
- Consumes: 既有接缝（LSBLK_BIN/BLKID_BIN）+ 新增 `TIMEOUT_BIN`
- Produces: `dw_scan_system_disks`（stdout：`设备|类型码` 每盘一行，0/1/2）；`dw_format_disk_lines`（stdout：`设备|容量|型号|TRAN|类型` 全部行）；menu 列盘查表

- [ ] **Step 1: 写 t6_scan.sh（H1-H9）并跑 fail**

  | 编号 | 断言 |
  |---|---|
  | H1 | menu 列盘典型流程 cmds.txt 无逐盘 lsblk/blkid/awk（枚举+批量探测各 1 次，其后列盘零新增命令） |
  | H2 | `dw_scan_system_disks`：假件 lsblk（含 PARTTYPENAME/PARTFLAGS 列）+ 假件 blkid（`-c /dev/null -o full` 形态输出 `设备: TYPE="..."`）→ ESP 盘 SYS(1)、ntfs SYS(1)、无签名 DATA(0)、探测不到 UNK(2)；输出 `设备|类型码` |
  | H3 | TIMEOUT_BIN=假件（返回 124）：批量探测返回空 → 全部盘标 UNK；菜单仍显示其余盘、不挂死 |
  | H4 | TIMEOUT_BIN 接缝：假件记录调用 `timeout 3 <cmd>`；生产默认 timeout |
  | H5 | 类型查表与 `dw_is_system_disk` 口径一致（SYS/DATA/UNK 映射不变） |
  | H6 | 枚举后屏幕含 `Scanning disks...`；日志含盘清单行 |
  | H7 | 枚举假件超时（124）→ menu 打印 `ERROR: disk scan timed out or failed` 并重试一次；重试仍失败 → 打印错误+可安全重启提示；**不出现** `Only boot media found` |
  | H8 | 清除流程 cmds.txt：wipefs/umount/partprobe 调用**无 timeout 前缀** |
  | H9 | `dw_disk_mountpoints` 与 init 日志介质探测调用包 `timeout 3`（cmds.txt 断言） |

  运行 `bash diskwipe-iso/tests/run-all.sh`（Git Bash），预期 t6 FAIL（新行为未实现）。

- [ ] **Step 2: lib.sh — dw_scan_system_disks + dw_format_disk_lines + TIMEOUT_BIN 接缝 + 只读探测包 timeout**

  批量探测实现（1 次 lsblk `-o NAME,TYPE,MOUNTPOINT,PKNAME,PARTTYPENAME,PARTFLAGS` + 1 次 blkid `-c /dev/null -o full`，awk 归并到父盘）；`dw_enum_disks`/`dw_disk_mountpoints` 调用包 `"$TIMEOUT_BIN" 3`。

- [ ] **Step 3: menu.sh — 列盘零 exec + 枚举降级 + 进度/日志**

  列盘循环改为查表（预计算全部 `设备|容量|型号|TRAN|类型` 行 + 类型码表），循环内零外部命令；枚举空/超时时打印错误并重试一次；枚举后打印 `Scanning disks... (please wait)`；枚举结果落日志。

- [ ] **Step 4: init — dw_mount_log_media 探测包 timeout**

- [ ] **Step 5: 回归 + 语法**

  `bash diskwipe-iso/tests/run-all.sh`（Git Bash）→ t1-t6 全 PASS；`bash --posix -n diskwipe-iso/src/*.sh diskwipe-iso/src/init` 0 错误。

- [ ] **Step 6: Commit**

  ```bash
  git add diskwipe-iso/src diskwipe-iso/tests
  git commit -m "fix(diskwipe-iso): 列盘循环零外部命令（批量探测+查表）+ 只读探测 timeout 兜底 + 枚举超时降级 + 进度/日志增强"
  ```

---

### Task 2: 构建（v1.3.0 重打包 + qemu 冒烟）+ README

**Files:**
- Modify: `diskwipe-iso/VERSION`（1.2.0 → 1.3.0）
- Modify: `diskwipe-iso/README.md`（列盘批量探测与超时说明）

**Interfaces:**
- Consumes: Task 1 的批量探测/超时实现（依赖 build 后 busybox timeout applet 可用）
- Produces: `output/diskwipe-v1.3.0.iso`

- [ ] **Step 1: VERSION 1.2.0 → 1.3.0**（保留 BOM 布局）

- [ ] **Step 2: 重新构建 + 校验 + qemu 冒烟**

  `bash diskwipe-iso/build.sh`（Git Bash）→ `output/diskwipe-v1.3.0.iso`；isoinfo 三关键文件 + initrd `/diskwipe.version`=1.3.0 + dash -n 0 错误；**qemu 冒烟**（1G virtio 盘 + 虚拟 U 盘）：横幅 `DiskWipe Tool 1.3.0`、列盘正常显示（含 SYS/DATA/UNK）、`Scanning disks...` 出现、虚拟盘清除 `OK /dev/vda reset to uninitialized`。

- [ ] **Step 3: README 更新**（列盘批量探测/超时/进度说明；交叉核对真实行为）

- [ ] **Step 4: 全量回归 + Commit**

  `bash diskwipe-iso/tests/run-all.sh` 全 PASS；
  ```bash
  git add diskwipe-iso/VERSION diskwipe-iso/README.md
  git commit -m "release(diskwipe-iso): v1.3.0 列盘卡住修复（零 exec + 超时兜底）重打包"
  ```

---

## 交付后重测指引（用户执行，README 同步）

v1.3.0 → IPMI KVM 进 → 观察 `Scanning disks...` 后列表出现 → 全选 → YES → 逐盘 OK/FAIL → 重启后 FirPE 复查。若仍卡，日志（已增强）定位。
