# diskwipe-iso 清理日志持久化落盘 设计

- 日期：2026-11-21
- 状态：待评审
- 依据：用户 2026-11-21 需求（清理日志要能保存到 U 盘/文件）+ brainstorming 确认

## 1. 背景与需求

现状：diskwipe-iso 的清理结果只输出屏幕（initramfs 内存盘，重启即失）。用户希望清理完成后有一份**可带走的日志**（记录这次清了哪些盘、结果如何）。

已确认口径：
- 日志目标：**自动写 U 盘可写分区**（FAT/exFAT，如 Ventoy 数据区）；找不到可写介质 → 仅屏幕输出并提示，**不阻断清理**。
- 文件形态：每次清理生成一个 `diskwipe-<YYYYmmdd-HHMMSS>.log`。
- 内容（全选）：基础信息（版本/起止时间）+ 盘清单（设备/容量/型号/类型）+ 每盘结果（✓/✗ 原因）+ 排除/跳过记录（U 盘/光驱/白名单外设备）。
- 归属：在现有 `diskwipe-iso/` 工具上加（增量）。

## 2. 目标

- init 启动时探测并挂载 U 盘可写分区到 `/diskwipe-log`；无则置 `DW_LOG_MEDIA=none`。
- menu.sh 初始化日志文件（时间戳文件名），清理过程输出 `tee` 到日志（屏幕保留）。
- 日志含四类内容；每盘结果与排除记录都落日志。
- 退出前卸载日志挂载（`0` 退出路径）。
- README 更新（U 盘需可写分区，推荐 Ventoy）；测试覆盖有/无介质两分支。

## 3. 非目标 / 反目标

- 非目标：不做日志轮转/压缩；不写目标盘（被清成未初始化写不了）；不改清理逻辑本身；不要求现场交互指定路径。
- 反目标：
  - **绝不把 U 盘当可清盘**（TRAN=usb 排除不变；挂载日志区不等于参与清除）。
  - 无可写介质时不阻断清理（只提示）。
  - 日志写入失败不导致清理失败（tee 失败仅提示）。
  - 不改变既有交互/清除/验证行为与测试。

## 4. 设计

### 4.1 init：U 盘可写分区探测与挂载

在 init 模块加载 + mdev 扫描之后、`exec menu.sh` 之前插入 `dw_mount_log_media`：

```text
1) 枚举 TRAN=usb 的整盘（lsblk -o NAME,TYPE,TRAN；TYPE=disk 且 TRAN=usb）
2) 对每块 U 盘，收集其 TYPE=part 分区中带可写文件系统（blkid TYPE ∈ vfat|exfat|ntfs）的分区
   - 排序：卷标 LABEL != VTOYEFI 的分区优先（跳过 Ventoy 32MB 启动分区，优先数据区）；
   - 依次尝试 mount 到 /diskwipe-log（mkdir -p 先建），挂载后写入测试（1 字节探测文件删除）验证可写
3) 任一成功 → export DW_LOG_MEDIA=usb；全部失败 → export DW_LOG_MEDIA=none
4) 光驱/无 U 盘 → DW_LOG_MEDIA=none
```

- 只挂载一个可写分区（按上述优先级第一个成功者），不挂多个。
- 挂载失败静默降级 none（提示在 menu 里给）。
- 注意：挂载点 `/diskwipe-log` 是 initramfs 内存目录，不影响 U 盘数据；U 盘本身仍在 menu 排除列表（TRAN=usb）不会进入可清盘。

### 4.2 menu.sh：日志初始化与 tee

- **日志粒度 = 一次启动会话一个文件**：menu 启动时（`DW_LOG_MEDIA=usb`）生成 `$LOG_DIR/diskwipe-$(date +%Y%m%d-%H%M%S).log` 并写文件头（版本、会话开始时间、介质状态）；会话内多轮清理结果都**追加**到同一文件；`0` 退出前写文件尾（会话结束时间）并 `umount /diskwipe-log`（尽力，失败仅提示）。
- `DW_LOG_MEDIA=none` 时打印提示"未找到可写日志介质，本次日志仅屏幕显示"（不阻断清理）。
- 清理执行：`wipe.sh <dev...> 2>&1 | tee -a "$LOG_FILE"`（保留屏幕输出）。menu 自身的列表/提示关键行（盘清单、每盘结果、排除记录）经 `dw_log <msg>`（`echo "$msg" | tee -a "$LOG_FILE"`）落日志。保持 POSIX/ash（不用进程替换）。
- **版本来源（消除漂移）**：build-lib.sh 把 `VERSION` 拷入 rootfs `/diskwipe.version`；lib.sh 新增 `dw_version`（读该文件，缺失回退 `unknown`）；menu 横幅与日志文件头改用 `dw_version`（不再硬编码）。
- 退出（`0`）前：若 `DW_LOG_MEDIA=usb`，打印日志路径 + `umount /diskwipe-log`（尽力，失败仅提示）。

### 4.3 日志内容（用户全选四类）

| 类 | 内容 |
|---|---|
| 基础信息 | 工具版本（VERSION）、开始/结束时间、介质状态（usb/none） |
| 盘清单 | 清理目标盘：设备、容量、型号、类型（系统盘/数据盘/未知） |
| 每盘结果 | 每盘 `✓ 已恢复未初始化` 或 `✗ <原因>`；失败汇总 |
| 排除/跳过记录 | 被排除的 U 盘/光驱设备名；白名单外设备跳过记录 |

- 时间戳前缀：每行 `[HH:MM:SS]`。
- 无介质时：日志仅屏幕（不生成文件），提示语照常。

### 4.4 无新依赖

- vfat/exfat 挂载依赖内核（Ubuntu generic 内置 vfat/exfat 驱动）与 busybox mount（支持）。无需新 apt 包。

## 5. 测试计划（tests/，假件注入，本机 Git Bash）

| 编号 | 场景 | 断言 |
|---|---|---|
| L1 | U 盘有可写分区（假 lsblk 含 sdc usb + sdc1 vfat） | init 挂载 sdc1 到 /diskwipe-log；DW_LOG_MEDIA=usb |
| L2 | 无 U 盘/无可写分区 | DW_LOG_MEDIA=none；menu 打印提示、不阻断 |
| L3 | 清理后日志文件生成 | menu 执行清理后 /diskwipe-log/diskwipe-*.log 存在，含盘清单/每盘结果/排除记录 |
| L4 | 挂载失败 | 降级 none，清理照常 |
| L5 | 退出卸载 | 0 退出路径含 umount /diskwipe-log |
| 回归 | 既有 t1/t2/t3 全部保持 PASS（交互/清除/枚举不受影响） | — |

## 6. 文档与交付

- README：新增"清理日志"小节——U 盘需可写分区（推荐 Ventoy/分区 U 盘）；日志位置 `/<U盘>/diskwipe-<时间>.log`（一次启动会话一份，多轮清理追加）；内容说明；无可写介质时仅屏幕。
- 版本号：v1.0.0 → **v1.1.0**（新增功能，次版本 +1）；重新 build.sh 出 iso（产物更新，output/ 不入库）。
- 构建变更（仅此两处，其余不变）：① build-lib.sh 把 `VERSION` 拷入 rootfs `/diskwipe.version`；② 无新依赖（vfat/exfat 挂载依赖内核内置驱动 + busybox mount）。

## 7. 留给实现者的决定 / 设计者已定

- 设计者已定：会话级日志（一次启动一份，多轮追加）；写 U 盘可写分区（跳过 VTOYEFI 卷标，写失败自动换下一个）；`diskwipe-<YYYYmmdd-HHMMSS>.log`；tee 保屏幕；无介质不阻断；退出前 umount；版本来源 = 构建拷入 `/diskwipe.version` + `dw_version`（消除横幅硬编码漂移）；v1.1.0。
- 留给实现者：init 里 U 盘分区枚举的 lsblk 解析细节；menu 内 `dw_log` 最小侵入写法（保持 POSIX/ash）；写入测试的具体实现；测试假件组织（沿用现有 tests/lib.sh）。
