# diskwipe-iso 清理日志持久化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** diskwipe-iso 清理完成后把日志持久化到 U 盘可写分区（会话级一份 `diskwipe-<时间>.log`），替代"仅屏幕输出"，并统一版本来源（v1.1.0）。

**Architecture:** init 新增 `dw_mount_log_media`（枚举 U 盘可写分区、跳过 VTOYEFI、mount+写测试，挂载到 /diskwipe-log）；menu.sh 启动时生成会话级日志文件、关键输出经 `dw_log`（tee）落日志、0 退出写文件尾并 umount；lib.sh 新增 `dw_version`/`dw_log`；build-lib.sh 把 VERSION 拷入 rootfs `/diskwipe.version`。全部保持 POSIX/ash。

**Tech Stack:** bash（POSIX/ash）、busybox（mount/vfat/exfat）、util-linux（lsblk/blkid）、假件注入测试

**Spec:** [2026-11-21-diskwipe-iso-log-design.md](../specs/2026-11-21-diskwipe-iso-log-design.md)

## Global Constraints

- 全部 src 脚本必须 POSIX/ash 兼容（initramfs 只有 busybox ash）；LF 行尾。
- 测试绝不触碰本机真实块设备（假件经接缝变量注入；wipefs 假件只记录）。
- U 盘（TRAN=usb）在可清盘列表**硬排除不变**；挂载日志区不等于参与清除。
- 日志目标：U 盘可写分区（vfat/exfat/ntfs），**跳过 VTOYEFI 卷标**优先数据区；写失败自动换下一个；全部失败 → `DW_LOG_MEDIA=none`，仅屏幕提示、**不阻断清理**。
- 日志粒度：**一次启动会话一份** `diskwipe-<YYYYmmdd-HHMMSS>.log`，多轮清理追加；文件头（版本/会话开始/介质状态）+ `0` 退出前文件尾（会话结束）+ umount。
- 日志内容四类：基础信息（版本/起止时间/介质状态）、盘清单（设备/容量/型号/类型）、每盘结果（✓/✗ 原因）、排除/跳过记录（U 盘/光驱/白名单外设备）。
- 版本来源：build-lib.sh 拷贝 `VERSION` → rootfs `/diskwipe.version`；`dw_version` 读取（缺失回退 `unknown`）；menu 横幅与日志文件头统一用它（消除硬编码漂移）。
- 版本号 v1.0.0 → **v1.1.0**；重新 build 出 iso；无新依赖（vfat/exfat 内核内置 + busybox mount）。
- 清理/交互/枚举既有行为与测试不受影响。

## Review Focus

- **Ventoy 布局**：U 盘第一个可写分区是 VTOYEFI（32MB 启动区），日志不得写进去 → 跳过 VTOYEFI 卷标、写失败自动换下一个（Task 1 L1 断言选中的数据分区）。
- **无可写介质**：只有光驱/无 U 盘/全是只读 → 不阻断清理、仅提示（Task 1 L2/L4）。
- **多轮清理**：一次会话多次 YES → 全部追加同一文件、不生成多个（Task 1 L3 断言单文件）。
- **tee 失败**：日志介质写满/卸载 → 清理结果仍显示屏幕、不失败（Task 1 L3 附场景）。
- **版本漂移**：菜单横幅与日志头必须来自 `/diskwipe.version`（构建拷入），不再硬编码 v1.0（Task 2 校验）。

---

### Task 1: src 日志功能（init/menu/wipe/lib）与测试

**Files:**
- Modify: `diskwipe-iso/src/lib.sh`（新增 `dw_version`、`dw_log`）
- Modify: `diskwipe-iso/src/init`（新增 `dw_mount_log_media` 调用）
- Modify: `diskwipe-iso/src/menu.sh`（日志初始化/文件头/关键行 dw_log/0 退出文件尾+umount；横幅改用 dw_version）
- Modify: `diskwipe-iso/src/wipe.sh`（每盘结果经 stdout 由 menu tee 捕获；如有自身 echo 关键行改 dw_log）
- Create: `diskwipe-iso/tests/t4_log.sh`
- Modify: `diskwipe-iso/tests/run-all.sh`（纳入 t4）

**Interfaces:**
- Consumes: 既有接缝变量（LSBLK_BIN/BLKID_BIN/UMOUNT_BIN）、menu 交互契约、`wipe.sh <dev...>`
- Produces:
  - `dw_version`（echo 版本号，读 `/diskwipe.version`，缺失回退 `unknown`）
  - `dw_log <msg>`（`echo "$msg" | tee -a "${LOG_FILE:-/dev/null}"`，POSIX 兼容；LOG_FILE 为空时仅 stdout）
  - `dw_mount_log_media`（init 内：枚举 U 盘可写分区→跳过 VTOYEFI→mount+写测试；设置并导出 `DW_LOG_MEDIA=usb|none`）
  - menu 内 `LOG_DIR=/diskwipe-log`、`LOG_FILE=$LOG_DIR/diskwipe-$(date +%Y%m%d-%H%M%S).log`

- [ ] **Step 1: 写 t4_log.sh 用例并跑 fail 阶段**

  用例（复用 tests/lib.sh 假件；LSBLK_BIN/BLKID_BIN/MOUNT_BIN/UMOUNT_BIN 假件扩展支持 TRAN/LABEL/挂载记录）：

  | 编号 | 场景 | 断言 |
  |---|---|---|
  | L1 | U 盘 sdc（sdc1 VTOYEFI vfat 32MB + sdc2 exfat 数据区） | `dw_mount_log_media` 挂载 **sdc2**（跳过 VTOYEFI）到 /diskwipe-log；`DW_LOG_MEDIA=usb` |
  | L2 | 无 U 盘（仅 sda 数据盘+光驱） | `DW_LOG_MEDIA=none`；menu 打印"未找到可写日志介质"，清理照常执行 |
  | L3 | 有介质 + menu 跑两轮清理（两次 YES） | /diskwipe-log 下**仅一个** `diskwipe-*.log`；内容含文件头（版本/会话开始/介质状态）、两轮盘清单、每盘结果、文件尾（会话结束） |
  | L4 | 挂载失败（假 mount 返回非 0） | 降级 `DW_LOG_MEDIA=none`，清理照常 |
  | L5 | `0` 退出路径 | 含文件尾 + `umount /diskwipe-log` |
  | L6 | `dw_version` 缺 `/diskwipe.version` | 回退 `unknown`；存在时读出版本号 |
  | L7 | tee 写入失败（日志目录只读/写满） | 清理结果仍显示屏幕、清理不失败 |

  运行 `bash diskwipe-iso/tests/run-all.sh`，预期 t4 FAIL（函数不存在）。

- [ ] **Step 2: 实现 lib.sh 的 `dw_version` 与 `dw_log`**

  按上述签名（`dw_version` 读 `/diskwipe.version`；`dw_log` tee 到 `${LOG_FILE:-/dev/null}`，LOG_FILE 未设置时仅 stdout）。

- [ ] **Step 3: 实现 init 的 `dw_mount_log_media`**

  按设计 §4.1：枚举 TRAN=usb 整盘 → 收集可写分区（blkid TYPE ∈ vfat|exfat|ntfs）→ 跳过 `LABEL=VTOYEFI` 优先 → 逐个 mount 到 /diskwipe-log + 写测试（1 字节探测文件删除）→ 首个成功置 `DW_LOG_MEDIA=usb`，全败置 `none`（POSIX，awk 解析 lsblk 列）。

- [ ] **Step 4: 实现 menu.sh 日志初始化与退出收尾**

  启动时：`dw_version` 进横幅与文件头；`DW_LOG_MEDIA=usb` → 生成 LOG_FILE 写文件头；`none` → 提示不阻断。清理输出经 `wipe.sh ... 2>&1 | tee -a "$LOG_FILE"`；盘清单/每盘结果/排除记录关键行走 `dw_log`。`0` 退出：写文件尾 + `umount /diskwipe-log`（尽力，失败仅提示）。

- [ ] **Step 5: 跑 t4_log.sh 全绿 + 回归**

  `bash diskwipe-iso/tests/run-all.sh`（Git Bash）→ t1+t2+t3+t4 全 PASS；`bash --posix -n diskwipe-iso/src/*.sh diskwipe-iso/src/init` 0 错误。

- [ ] **Step 6: Commit**

  ```bash
  git add diskwipe-iso/src diskwipe-iso/tests
  git commit -m "feat(diskwipe-iso): 清理日志持久化（U盘可写分区挂载 + 会话级日志 + dw_version/dw_log）"
  ```

---

### Task 2: 构建（VERSION 拷入 + v1.1.0 重打包）+ README

**Files:**
- Modify: `diskwipe-iso/build-lib.sh`（拷贝 VERSION → rootfs `/diskwipe.version`）
- Modify: `diskwipe-iso/VERSION`（1.0.0 → 1.1.0）
- Modify: `diskwipe-iso/README.md`（新增"清理日志"小节）

**Interfaces:**
- Consumes: Task 1 的 `dw_version`（依赖构建拷入的 `/diskwipe.version`）
- Produces: `output/diskwipe-v1.1.0.iso`（重打包，含日志功能 + 版本文件）

- [ ] **Step 1: build-lib.sh 拷贝 VERSION 到 rootfs**

  在组装 rootfs 拷贝 src 四脚本处，追加拷贝 `VERSION` → `<rootfs>/diskwipe.version`（保持幂等）。

- [ ] **Step 2: VERSION 1.0.0 → 1.1.0**

  写 `1.1.0`（保留 BOM 布局）。

- [ ] **Step 3: 重新构建 + 校验**

  `bash diskwipe-iso/build.sh`（Git Bash，WSL 清华源已就绪）→ 生成 `output/diskwipe-v1.1.0.iso`；isoinfo 校验三关键文件；解包 initrd 确认 `/diskwipe.version` = `1.1.0`；src 脚本 `dash -n` 0 错误；**qemu 冒烟复验**（挂 1G virtio 盘 + 假 U 盘可写分区场景尽可能覆盖；至少确认菜单出现与横幅含 `v1.1.0`）。

- [ ] **Step 4: README 新增"清理日志"小节**

  内容：U 盘需可写分区（推荐 Ventoy/分区 U 盘）；日志位置 `/<U盘>/diskwipe-<时间>.log`（会话级一份，多轮追加）；内容四类；无可写介质时仅屏幕不阻断；VTOYEFI 跳过说明。交叉核对真实行为。

- [ ] **Step 5: 全量回归 + Commit**

  `bash diskwipe-iso/tests/run-all.sh` 全 PASS；`--posix -n` 0 错误；
  ```bash
  git add diskwipe-iso/build-lib.sh diskwipe-iso/VERSION diskwipe-iso/README.md
  git commit -m "release(diskwipe-iso): v1.1.0 清理日志持久化（VERSION 拷入 initramfs + 重打包 + README）"
  ```
