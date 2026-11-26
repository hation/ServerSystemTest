# task-v133 报告：diskwipe-iso v1.3.3 修复「menu 批量类型探测 blkid 全盘扫描读 U 盘导致卡死」

日期：2026-11-22　｜　分支基线：`70984c6`（v1.3.2）

## 1. 状态

**完成**。v1.3.3 已实现、全量测试回归 PASS（355 项）、ISO 重打包 + qemu 冒烟（含 USB 盘场景）**PASS**。

## 2. 根因与修复（src/lib.sh `dw_scan_system_disks`，193 行起）

真机 v1.3.2 卡点：批量类型探测的 `blkid -c /dev/null -o full` **无设备参数全盘扫描**会读所有块设备（含启动 U 盘 sdb）；U 盘 I/O 阻塞为内核 D 状态不可中断，`timeout`（SIGTERM）无效 → blkid 卡死 → 菜单枚举卡死（真机 dmesg：U 盘枚举完成 `sdb: sdb1 sdb2` 后无输出，`hub_event hogged CPU`）。

v1.3.3 改动（按设计实现，含一处**实证修正**）：

- **新增一次 lsblk 拿 TRAN**（与 `dw_save_log_to_usb` 同形态）：`"$TIMEOUT_BIN" 3 "$LSBLK_BIN" -o NAME,TYPE,TRAN,PKNAME -l` → awk 收集 **TYPE=disk、白名单内、TRAN!=usb** 的盘（`sr/loop/ram` 双保险排除），再输出**这些盘的分区设备列表**（带 `/dev/` 前缀；分区行 PKNAME 恒为末列）。TRAN 只出现在整盘行（同 save_log 口径）。
- **blkid 改为带分区设备参数**：`"$TIMEOUT_BIN" 3 "$BLKID_BIN" -c /dev/null -o full /dev/sda1 /dev/sdb1 ...`——**U 盘及其分区不在参数中，blkid 不读 U 盘**（根治点）。列表为空（无非 USB 盘分区）→ 跳过 blkid（dwsfs 空，无分区盘判 DATA）。
- **实证修正（设计偏离点）**：设计原为「带整盘参数 /dev/sda /dev/sdb」；WSL 回环盘实证 **util-linux `blkid -o full <整盘>` 只输出该盘 PTTYPE、不会探测其分区**（`blkid -o full /dev/loop0` 无 `/dev/loop0p1: TYPE="ntfs"`）→ 整盘参数拿不到分区 TYPE，类型判定全 UNK（冒烟首轮 vda 实测 UNK 暴露）。改为**分区设备参数**后首轮 SYS/DATA/UNK 正确（冒烟复测 PASS）。对 U 盘排除更彻底（连目标盘整盘都不读，只读目标分区）。
- 后续 awk 归并解析**不变**（`blkid -o full` 带分区参数同样输出 `设备: TYPE="..."` 每行）。
- 注释（原 191-192 行）已更新：说明 TRAN 过滤排除 USB（menu 枚举已排除 usb，双保险）。
- 原有 lsblk 全盘表调用（PARTTYPENAME/PARTFLAGS 列）保持不变。
- 第二轮冒烟实测「清盘后全盘无分区 → 跳过 blkid → 全 DATA」路径真实生效（正确）。

## 3. 测试适配与新增（tests/）

- **tests/lib.sh 假 blkid**：full 模式且带 `/dev/*` 参数时，**只输出参数中设备的条目**（参数即分区名，按 blk.type 键直接匹配；参数设备不在 blk.type → 无输出 rc 0）；无设备参数（全盘）保持输出全表。单设备 `-s TYPE|-s LABEL -o value` 形态不变。
- **tests/lib.sh 假 lsblk TRAN 模式**：补输出表头 `NAME TYPE TRAN PKNAME`（与真实 lsblk 一致——v1.3.3 的 lib.sh 过滤 `NR==1` 跳表头；原假件缺表头会把第一个盘当表头跳过，导致 blkid 参数丢失首盘，已修正）。
- **tests/t2_menu.sh**：M7 自定义假 lsblk 补 `NAME,TYPE,TRAN,PKNAME` 分支（同 install_fakes 形态）。
- **tests/t6_scan.sh**：
  - H1：lsblk 调用计数 3 → 4（枚举 + 批量全盘表 + TRAN + 退出写 U 盘枚举）；blkid 断言改为带**分区**参数整行（`/dev/sda1`）+ 无逐盘 `blkid -s`。
  - H2：lsblk 计数 1 → 2；blkid 断言改为 `... -o full /dev/sda1 /dev/sdb1 /dev/sdc1 /dev/sdd1`（sde 无分区）；新增 TRAN lsblk 断言。
  - **新增 H10**：U 盘存在（lsblk.table 含 TRAN=usb 盘）时，`dw_scan_system_disks` 的 blkid 调用**不含 U 盘设备**（记录版 timeout 断言 cmds.txt：`timeout 3 blkid -c /dev/null -o full /dev/sda1 /dev/sdb1` 无 `/dev/sdc`；且 U 盘分区也配了 blk.type 条目反证未被读）；非 USB 盘类型判定正确（SYS/DATA 口径不变）。

## 4. 测试结果（单独跑各 t，全 PASS）

| 组 | 项数 | 结果 |
|---|---|---|
| t1_wipe | 89 | ALL PASS |
| t2_menu | 61 | ALL PASS |
| t3_init | 45 | ALL PASS |
| t4_log | 46 | ALL PASS |
| t5_ascii | 37 | ALL PASS |
| t6_scan | 77 | ALL PASS（v1.3.2 为 68，新增 H10 等 9 项） |
| **合计** | **355** | **ALL PASS**（v1.3.2 为 346） |

- POSIX 语法：`bash --posix -n src/*.sh src/init` 0 错误。
- 说明：run-all 在 Windows 下慢（600s+），按任务要求以**单独跑全部通过**为准。

## 5. 版本与 README

- `VERSION`：1.3.2 → **1.3.3**。
- `README.md`：§1 新增 v1.3.3 changelog（blkid 只带非 USB 盘参数、不读 U 盘；qemu 冒烟含 USB 场景）；§7 列盘 bullet 补充 v1.3.3 说明；§9/§2 测试计数 346 → 355（t6 68 → 77）；§10 重测指引改为 v1.3.3（重点：U 盘存在时菜单立即出现，不再卡在「U 盘枚举完成（sdb: sdb1 sdb2）后无任何输出」）；当前版本号引用（横幅/dd/Rufus/产物路径）精确替换为 1.3.3，v1.3.1/v1.3.2 历史段语义未动。

## 6. 打包与 qemu 冒烟（**PASS**）

- `bash diskwipe-iso/build.sh`（Git Bash → WSL）：成功产出 `output/diskwipe-v1.3.3.iso`（77M）；isoinfo 校验全部通过（含 initrd 内 `/diskwipe.version = 1.3.3`、src 四脚本 dash -n 0 错误）。
- qemu 冒烟 `tmp/dw-smoke-v133.sh`（参考 v132 改 v133，盘布局含 **USB 盘场景**：vda ntfs→SYS、vdb 空白→DATA、vdc 分区无 fs→UNK、sda USB(VTOYEFI+DWLOGTEST)）——**verdict PASS**，关键行：
  - `DiskWipe Tool 1.3.3 - Reset disks to uninitialized`（横幅）
  - `Scanning disks... (please wait)` → `Disks found: 3 (vda vdb vdc)`（**U 盘存在时菜单立即出现**，无卡死）
  - 首轮：`/dev/vda ... SYS`、`/dev/vdb ... DATA`、`/dev/vdc ... UNK`
  - `OK /dev/vda|vdb|vdc reset to uninitialized` 三盘全过
  - `Exited. You may power off or reboot after done.` / `Log kept in memory:` / `Cleanup log saved to USB`
  - 无 ERROR / 无 Only boot media / 无 No writable log media
  - USB 数据区存在 `diskwipe-20261122-090428.log`（`log media: memory (/tmp/diskwipe-log)`，版本 1.3.3）
  - 第二轮（清盘后）：vda/vdb/vdc 全 DATA——「无分区 → 跳过 blkid」路径真实生效
  - 冒烟记录：`tmp/dw-smoke-v133.out`、`tmp/dw-smoke-v133-keylines.txt`、`tmp/dw-smoke-v133b-run.txt`

## 7. 提交

1. `0fe8011 fix(diskwipe-iso): 批量类型探测 blkid 排除 U 盘（不读 U 盘），修复 U 盘 I/O 阻塞卡死`（src/lib.sh + tests/lib.sh + tests/t2_menu.sh + tests/t6_scan.sh）
2. `bd958ad release(diskwipe-iso): v1.3.3 重打包（qemu 冒烟：横幅 1.3.3/U 盘存在时菜单立即出现/三盘 SYS-DATA-UNK/OK 全过/日志写 U 盘）`（VERSION + README.md）

## 8. 遗留/concerns

- 无功能遗留。备注：`dw_is_system_disk`（保留的逐盘旧口径）内部 `blkid -s TYPE -o value` 未包 timeout——menu 已不调用（仅测试对照），v1.3.3 不触碰，属既有设计。
- 假 lsblk TRAN 模式补表头为「与真实 lsblk 对齐」的既有假件缺陷修正（原缺表头时首个盘会被 `NR==1` 跳过——对 save_log 无影响、对 v1.3.3 新过滤有影响，已一并修）。
- 设计与实现的唯一偏离：blkid 参数从「整盘」改为「分区」（实证 util-linux 整盘参数只出 PTTYPE、不探分区；分区参数同样达成「U 盘不读」目标且更彻底），README/§1/§7/§10 与注释均已按分区参数表述。
