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

