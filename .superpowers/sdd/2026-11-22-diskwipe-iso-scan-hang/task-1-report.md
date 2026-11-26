# Task 1 报告：src 修复（列盘零 exec + timeout 兜底 + 枚举降级 + 进度/日志）与测试

- 日期：2026-11-22
- Commit：`4cfbd16 fix(diskwipe-iso): 列盘循环零外部命令（批量探测+查表）+ 只读探测 timeout 兜底 + 枚举超时降级 + 进度/日志增强`
- 状态：DONE

## 1. 实现了什么

### src/lib.sh（`diskwipe-iso/src/lib.sh`）
- 新增接缝 `TIMEOUT_BIN="${TIMEOUT_BIN:-timeout}"`（busybox 已含 timeout applet）。
- **`dw_scan_system_disks()`**（新）：一次 lsblk `-o NAME,TYPE,MOUNTPOINT,PKNAME,PARTTYPENAME,PARTFLAGS` + 一次 blkid `-c /dev/null -o full`，awk 归并到父盘，stdout 每盘一行 `设备|类型码`（0=DATA/1=SYS/2=UNK）。探测口径与 `dw_is_system_disk` 完全一致（tolower 匹配类型名含 EFI、MBR 0x80、ntfs、全已知无迹象→DATA、存在探测不到→UNK、无分区→DATA）。两段输入（blkid 段 / lsblk 段）用哨兵行 `__DWS_END__` 分隔（单 stdin 流下 NR==FNR 不可用）。两个外部调用均包 `"$TIMEOUT_BIN" 3`；任一次超时/失败 → 返回 1 且无输出（调用方全部盘标 UNK）。
- **`dw_format_disk_lines()`**（新）：stdin 枚举行 → stdout 全部 `设备|容量|型号|TRAN大写|类型码` 行；$1 为类型码表（`dw_scan_system_disks` 输出），空/缺失 → 全部盘标 UNK(2)。类型码表经 shell 拼为空格分隔串传 awk `-v lookup`（设备名无空格，POSIX awk 全兼容）。
- **只读探测包 timeout**：`dw_enum_disks`（lsblk）、`dw_disk_mountpoints`（lsblk）、`dw_mount_log_media`（枚举 lsblk + 逐候选 blkid TYPE/LABEL）全部包 `"$TIMEOUT_BIN" 3`；超时/失败返回 1 且输出空。**清除操作（umount/wipefs/partprobe）不加 timeout**。`dw_is_system_disk` 保留（供查表口径对照，menu 不再调用）。
- 树形前缀剥离改用 `sub(/^[^a-z0-9]+/, "", name)`（locale 安全，兼容 busybox awk 按字节处理）。

### src/menu.sh（`diskwipe-iso/src/menu.sh`）
- 删除逐行 awk 的 `disk_display_fields`（被 `dw_format_disk_lines` 取代）。
- **枚举超时降级**：`dw_enum_disks` 返回非 0（超时/失败）→ 打印 `ERROR: disk scan timed out or failed` 并重试一次；仍失败 → `ERROR: disk scan failed. You may power off or reboot safely.` + `dw_log_finish` + exit 1。**枚举成功但为空**（rc=0，仅 usb+光驱）才走既有 `Only boot media found` 退出路径（M6 契约保持）。绝不把超时误判为"仅启动介质"。
- **列盘零 exec**：枚举后打印 `Scanning disks... (please wait)` → 批量探测（`dw_scan_system_disks`）+ 批量格式化（`dw_format_disk_lines`）预计算 → 列表/确认循环内仅 `${var%%|*}` 纯 shell 切分 + `disk_type_label` 纯 shell case + `printf` 内建，零外部命令；选中循环用 `${mline%% *}` 取设备名（枚举行首字段）。
- **进度/日志**：枚举后 `Scanning disks... (please wait)`；`dw_log "Disks found: N (dev list)"` 落日志（一次 tee，不进循环）；盘清单照旧在确认块逐盘落日志。

### src/init（`diskwipe-iso/src/init`）
- **无需改动**：timeout 兜底实现在 lib.sh 的 `dw_mount_log_media`（init source lib.sh 即生效）。简报将 init 列为 modify，实际改动落在 lib.sh（t3 验证 init 全流程通过）。

### tests/
- `tests/t6_scan.sh`（新，H1-H9，66 项断言）：
  - H1 列盘典型流程 cmds.txt 无逐盘 lsblk/blkid（枚举+批量各 1 次，`check_not_cmds '/dev/sd'`）
  - H2 `dw_scan_system_disks` 输出 `设备|类型码`（ESP→1、ntfs→1、ext4 无标志→0、探测不到→2、无分区→0）+ 调用形态（`timeout 3 lsblk -o ...PARTTYPENAME,PARTFLAGS` / `timeout 3 blkid -c /dev/null -o full`）
  - H3 仅批量探测假 timeout 返 124 → 全部盘 UNK、菜单不挂死、不出现枚举 ERROR / Only boot media
  - H4 记录假件验证 `timeout 3 <cmd>` 形态 + 生产默认 `TIMEOUT_BIN=timeout`
  - H5 查表码与 `dw_is_system_disk` 逐盘一致（SYS=1/DATA=0/UNK=2）
  - H6 屏幕含 `Scanning disks... (please wait)`；日志含 `Disks found: 2 (sda sdb)` 与盘清单行
  - H7 枚举假 timeout 恒 124 → ERROR + 重试一次（lsblk 2 次）+ 安全重启提示 + 无 Only boot media + exit 1
  - H8 清除流程 wipefs/umount/partprobe 无 timeout 前缀（整行精确匹配 + `check_not_cmds 'timeout 3 wipefs'` 等）
  - H9 `dw_disk_mountpoints` 与 `dw_mount_log_media`（lsblk/blkid TYPE/LABEL）均包 timeout 3；mount 无前缀
- `tests/lib.sh`：假 lsblk 增批量列 `NAME,TYPE,MOUNTPOINT,PKNAME,PARTTYPENAME,PARTFLAGS`（ptname/flags 从 `lsblk.ptname`/`lsblk.flags` 查）；假 blkid 增批量形态 `-c /dev/null -o full` → `设备: TYPE="x"`（无条目 rc 0）；新增透明假 `timeout`（`shift` 后转执行，不记录 → 既有 check_no_cmds/check_cmds 不受影响）。
- `tests/t2_menu.sh`：M7 自定义假 lsblk 补批量列形态（叠加已清盘分区过滤）。
- `tests/t3_init.sh`：setup_stub 补透明假 timeout（隔离宿主 timeout）。
- `tests/run-all.sh`：加 `t6_scan`。

## 2. TDD 证据

- **RED**：写完 t6（含测试基建同步）后运行 → t6 39 FAIL（H1-H9 新行为全未实现），t1-t5 保持 281 PASS（89/61/44/50/37）。
- **GREEN**：实现 src 后运行 → t1-t5 281 PASS 不变 + t6 66 PASS，合计 **347 PASS / 0 FAIL**，`==== 全部测试: ALL PASS ====`。
- `bash --posix -n diskwipe-iso/src/lib.sh diskwipe-iso/src/menu.sh diskwipe-iso/src/wipe.sh diskwipe-iso/src/init` → 0 错误；src+tests 无 CR（LF）。

## 3. 既有断言同步清单

| 文件 | 同步内容 | 原因 |
|---|---|---|
| tests/t2_menu.sh | M7 自定义假 lsblk 增加批量列 `NAME,TYPE,MOUNTPOINT,PKNAME,PARTTYPENAME,PARTFLAGS` 处理（含已清盘分区过滤） | menu 现调用批量探测；原假件缺该列形态会返回空 → 类型全 UNK，M7 的 SYS=1/DATA=3 断言将失败 |
| tests/t3_init.sh | setup_stub 增加透明假 timeout | init 内 dw_mount_log_media 走 TIMEOUT_BIN 接缝；隔离宿主 timeout，保持 cmds.txt 断言不变 |
| tests/lib.sh | 假 lsblk 增批量列；假 blkid 增 `-o full` 形态；增透明假 timeout | 支撑 dw_scan_system_disks / timeout 接缝测试 |
| tests/run-all.sh | 增加 t6_scan | 纳入新测试 |

t1/t4/t5 断言未受影响（透明假 timeout 不记录 cmds.txt，输出形态不变）。t5 的 N1/N2/N6 在批量路径下保持 PASS（N2 的 SYS/DATA/UNK 现由批量探测产出，断言不变）。

## 4. 文件变更

- M `diskwipe-iso/src/lib.sh`（+169；TIMEOUT_BIN 接缝、dw_scan_system_disks、dw_format_disk_lines、只读探测包 timeout）
- M `diskwipe-iso/src/menu.sh`（列盘查表零 exec、枚举降级重试、Scanning/Disks found 日志、删除 disk_display_fields）
- A `diskwipe-iso/tests/t6_scan.sh`（H1-H9）
- M `diskwipe-iso/tests/lib.sh`、`tests/t2_menu.sh`、`tests/t3_init.sh`、`tests/run-all.sh`

## 5. 自审结论

- 列盘/确认/选中三个循环逐行确认零外部命令（仅 shell 内建 + 预计算数据）。
- `dw_scan_system_disks` 用真实形态树形输出（`├─` 前缀、无 PKNAME 列、ptname 多词、0x80 并列）做了额外手工验证（sda/sdb/sdc 全部正确判 SYS），覆盖假件未覆盖的真实 lsblk 形态。
- timeout 只覆盖只读探测；wipefs/umount/partprobe/mount 均无前缀（H8/H9 断言 + 代码审阅）。
- 枚举空 vs 超时的区分靠 rc（超时/失败 rc≠0 → 降级重试；rc=0+空 → 仅启动介质），M6 契约保持。

## 6. 遗留关注（Concerns）

1. 真实 busybox awk 的 `match()/tolower()/split()` 与 `sub(/^[^a-z0-9]+/, ...)` 均为 POSIX 特性，理论上兼容；busybox timeout applet 存在性依设计 §5.3 已确认（build 无需新增），但仍建议 v1.3.0 打包后 qemu 冒烟复验（设计 §7）。
2. 真实 lsblk 树模式是否输出 PKNAME 列不确定——已内置"无 PKNAME 时按分区名推导父盘"兜底，两种形态均正确。
3. 批量探测任一方超时即"全部盘标 UNK"（设计裁定）：类型仅提示，不影响清除语义。
4. 枚举第二次仍失败时退出码为 1（区别于 M6 的 0）——这是"扫描失败"路径，符合"不误判仅启动介质"。
5. src/init 未改动（timeout 兜底经 lib.sh 生效）；简报文件清单含 init，实际变更落在 lib.sh——不影响行为，t3 全过验证。

## 7. 验证命令（复跑）

```
"C:\Program Files\Git\bin\bash.exe" -lc "cd <repo> && bash diskwipe-iso/tests/run-all.sh"
bash --posix -n diskwipe-iso/src/lib.sh diskwipe-iso/src/menu.sh diskwipe-iso/src/wipe.sh diskwipe-iso/src/init
```
