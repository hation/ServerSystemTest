# diskwipe-iso v1.3.1 日志介质写超时降级（修复「U 盘写入卡死」） 设计

- 日期：2026-11-22
- 状态：已实现（v1.3.1，commit ac90bb5/abc116e）
- 依据：用户 2026-11-22 真机测试反馈（v1.3.0 进菜单"屏幕只有内核日志、无菜单内容"即卡死）+ 上传 dmesg 日志

## 1. 背景与问题

用户用 v1.3.0 iso 真机测试：进入菜单前即卡死，屏幕上只有内核启动日志（dmesg），无任何菜单内容。

上传日志关键线索：U 盘 sdb 被识别（`sdb: sdb1 sdb2`），**`exFAT-fs (sdb1): Volume was not properly unmounted`** —— sdb1（exFAT 数据区）**已挂载成功**（init 阶段 `dw_mount_log_media` 挂载日志介质），此后 dmesg 无更多输出 → 卡在**挂载之后的首次写**。

## 2. 根因分析

- v1.3.0 只给**只读探测**（lsblk/blkid）加了 `timeout 3` 兜底；**日志介质写操作完全无超时**：
  - 挂载后可写性测试（`printf 'x' > $DW_LOG_PROBE`，lib.sh:418）无 timeout
  - `dw_log` 写日志文件（`tee -a`，lib.sh:372）无 timeout
- U 盘写 I/O 阻塞（exFAT 未正常卸载 + 盘慢/坏）→ 写测试无限挂起 → init 永不进入菜单。
- 现场确认（brainstorming）：卡死时屏幕只有内核日志（无菜单）→ 卡在 init 挂载后的写测试阶段。

## 3. 目标 / 非目标

- 目标：日志介质**写操作**也纳入超时兜底；坏/慢 U 盘不再拖死菜单与清除；正常 U 盘实时落盘行为不变；v1.3.1。
- 非目标：不改清除算法（umount/wipefs/partprobe 不加 timeout——破坏性操作不能半途中断）；不改交互契约；不做日志批量落盘重构。

## 4. 设计（已实现）

### 4.1 写测试超时（init 阶段，根治本次卡死）

- `dw_mount_log_media` 可写性测试改：`"$TIMEOUT_BIN" 3 sh -c 'printf x > "$1" && rm -f "$1"' sh "$DW_LOG_PROBE"`——写+删包 3 秒超时；超时/失败 → 该候选降级（继续下一个/最终 none），init 不被拖死。

### 4.2 dw_log 写超时 + LOG_DEGRADED 降级（菜单阶段兜底）

- `dw_log` 改：`echo "$1" | "$TIMEOUT_BIN" 2 tee -a "${LOG_FILE:-/dev/null}"`——tee 写 U 盘卡 2 秒 → 超时 → 置 `LOG_DEGRADED=1` + 一次性 `WARN: cleanup log media failed; log is screen-only`；后续 dw_log 仅屏幕（`echo`），不反复等超时。
- 管道末命令（timeout）返回码判定失败（POSIX ash 无 pipefail，rc 取 timeout 的）。

### 4.3 清除结果行降级检查

- `menu.sh` 的 wipe 结果 tee：`LOG_DEGRADED=1` 时仅屏幕（`"$WIPE_SH" $msel 2>&1`），否则 `tee -a`。**tee 不包 timeout**——写管道超时可能 SIGPIPE 中断 wipe.sh（危险），改由前置 dw_log 写失败触发降级。

### 4.4 版本与验证

- VERSION 1.3.0 → 1.3.1；README §1 更新日志 + §10 重测指引同步。
- 测试（tests/t4_log.sh 新增 L8/L9/L10 + tests/lib.sh 假 timeout 加 timeout.writetest/timeout.tee 开关）：
  - L8：写测试超时 → 降级 none，不挂起
  - L9：dw_log tee 超时 → LOG_DEGRADED=1 + WARN + 后续仅屏幕 + 日志不写入
  - L10：menu 全流程 + 写超时 → 清理照常 + 0 退出正常
- 全量回归：t1-t6 共 **364 PASS**（run-all.sh 全过）；`bash --posix -n src/*` 0 错误。
- qemu 冒烟（真实 initramfs busybox timeout）：横幅 **1.3.1**、列盘 SYS/DATA/UNK、三盘 OK、日志落盘、无 ERROR。

## 5. 交付与验收

- 产物：`diskwipe-iso/output/diskwipe-v1.3.1.iso`（76.8MB，BIOS+UEFI 双引导）。
- 真机重测（README §10）：v1.3.1 → IPMI KVM 进 → 菜单正常出现（即使 U 盘写入异常仅提示 WARN、不影响操作）→ 全选 → YES → 逐盘 OK/FAIL → 重启后 FirPE 复查。
