# diskwipe-iso v1.3.2 根治「init 阶段 U 盘 I/O 卡死进不去」 设计

- 日期：2026-11-22
- 状态：已实现（v1.3.2，commit 40a7600/85778e1）
- 依据：用户 2026-11-22 真机复测反馈（v1.3.1 仍进不去）+ 上传 dmesg

## 1. 背景与问题

用户用 v1.3.1 iso 真机复测：**仍然进不去**（屏幕只有内核日志，无菜单内容）。上传 dmesg 与 v1.3.0 时几乎一致：U 盘 sdb1（exFAT 数据区）挂载成功（`exFAT-fs (sdb1): Volume was not properly unmounted`）后无输出；且出现 `workqueue: hub_event hogged CPU`（USB 子系统异常迹象）。

## 2. 根因分析

- v1.3.1 已给只读探测与日志介质写测试/写日志加 `timeout` 兜底，**但对 U 盘写 I/O 阻塞（内核 D 状态，不可中断睡眠）无效**：`timeout` 发送 SIGTERM 无法打断 D 状态进程，`timeout` 自身也在等待该进程 → 一起挂起。
- 卡点在 **init 阶段的 `dw_mount_log_media`**（挂载 U 盘 + 可写性测试）——U 盘 I/O 阻塞时 D 状态挂起，菜单永不出现。
- 关键认识：**init 阶段任何 U 盘 I/O（含只读 blkid 探测）都可能卡死**——D 状态是设备 I/O 层问题，读写都会卡。根治必须**init 零 U 盘 I/O**。

## 3. 目标 / 非目标

- 目标：init 阶段**零 U 盘 I/O**（不挂载、不写测试、不探测）→ **菜单必现**；日志改**写内存**；**0 退出时尽力写 U 盘**（正常 U 盘可存，异常 U 盘提示可断电）；v1.3.2。
- 非目标：不改清除算法与交互契约；不保证"会话中途断电日志不丢"（内存日志断电即失，属权衡——工具可用优先）；不做 USB 栈层面的修复（超出工具范围）。

## 4. 设计（已实现）

### 4.1 init 零 U 盘 I/O

- `src/init` 第 4 步重试循环**删除 `dw_mount_log_media` 调用**（保留 `mdev -s` + `sleep 2` 补建设备节点）；`dw_mount_log_media` 函数整体删除（无调用方）。init 不再触碰任何 U 盘设备。

### 4.2 日志改内存（menu 阶段）

- `src/menu.sh`：`LOG_DIR="${LOG_DIR:-/tmp/diskwipe-log}"`（tmpfs 内存），menu 启动**无条件**创建会话日志（不再依赖 `DW_LOG_MEDIA=usb`）；删除 `No writable log media found; log will be screen-only.` 分支。
- `LOG_DEGRADED` 机制保留（内存写失败理论极小，防御保留）。

### 4.3 退出时尽力写 U 盘

- 新增 `dw_save_log_to_usb()`（lib.sh）：枚举 U 盘可写分区候选（lsblk TRAN=usb → blkid TYPE ∈ vfat|exfat|ntfs、跳过卷标 VTOYEFI，全部包 `timeout 3`）→ 逐个挂载（包 `timeout 3`；若 D 状态阻塞则 timeout 同样挂起——**可接受**，此时清除已完成，提示可断电）→ `cp` 日志 → `umount`。成功返回 0，全败返回 1。
- `dw_log_finish`：写文件尾 → 打印 `Log kept in memory: $LOG_FILE` → 调 `dw_save_log_to_usb` → 成功 `Cleanup log saved to USB` / 失败 `WARN: could not write log to USB (disk I/O blocked or no USB); log kept in memory: $LOG_FILE`。

### 4.4 版本与验证

- VERSION 1.3.1 → 1.3.2；README §1 更新日志 + §10 重测指引。
- 测试（tests/t4_log.sh 重写 + tests/lib.sh 适配）：
  - L1：menu 无 U 盘 → 内存日志（文件头/盘清单/结果/文件尾）+ 退出 WARN（日志保留内存）+ 清理照常
  - L2：menu 全流程两轮 → 内存日志两轮内容
  - L3：`dw_save_log_to_usb` 成功（挂载+cp+umount）
  - L4：`dw_save_log_to_usb` 挂载失败 → 返回 1（降级）
  - L5：init 无 `mount /dev/`（t3 I1 断言）；`dw_mount_log_media` 已删除
  - L6：dw_log 写内存正常（LOG_DEGRADED 未触发）
  - 全量回归 **346 PASS**（t1-t6 单独 + run-all 全量）。
- qemu 冒烟 **15/15 PASS**：菜单立即出现（横幅 1.3.2）、无 exFAT/VTOYEFI 挂载消息、列盘 SYS/DATA/UNK、三盘 OK、日志内存 + 退出写 U 盘成功落盘。

## 5. 交付与验收

- 产物：`diskwipe-iso/output/diskwipe-v1.3.2.iso`（77M，BIOS+UEFI 双引导，isoinfo 校验含 /diskwipe.version=1.3.2）。
- 真机重测（README §10）：v1.3.2 → **直接进菜单**（无论 U 盘是否异常）→ 全选 → YES → 逐盘 OK/FAIL → 0 退出（正常 U 盘日志落 U 盘；异常 U 盘提示日志在内存、可抄录后断电）。
