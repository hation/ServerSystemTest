# diskwipe-iso v1.2.0 真机"列盘卡住"修复（列盘零 exec + 超时兜底 + 进度反馈） 设计

- 日期：2026-11-22
- 状态：待评审
- 依据：用户 2026-11-22 真机测试反馈（v1.2.0，日志 `diskwipe-20261122-033627.log`）+ brainstorming 澄清

## 1. 背景与问题

用户用 v1.2.0 iso 真机测试：**进入菜单后尚未输入，界面即卡住**。上传日志停在文件头 + 横幅（`DiskWipe Tool 1.2.0 - Reset disks to uninitialized`），无任何后续。

已确认现象（brainstorming 澄清）：
- 卡住时屏幕**只看到横幅/表头**（列表一行未显示）
- 等待 <30 秒即判定卡住
- 该服务器 ≤8 块盘

## 2. 根因分析

- 日志有横幅 ⇒ `dw_enum_disks`（1 次 lsblk）已完成；卡点在**列盘循环**（menu.sh:118-139），该循环不写日志，故日志无痕。
- 列盘循环对**每块盘**启动外部命令：`disk_display_fields`（1 次 awk）+ `dw_is_system_disk`（1 次 lsblk + **每分区 1 次 blkid**）。第一块盘显示前即需多次 exec。
- ≤8 块盘排除"循环总量慢"假设 ⇒ 结论：**第一个外部命令调用挂起**——最可能是 blkid 读取块设备元数据时 I/O 阻塞（压测后设备状态/U 盘 initramfs exec 卡顿），整个循环被拖死，`>` 提示符永不出现。
- 次要弱点（同样需修）：即使不挂起，逐盘多次 exec 在盘多时也慢；且无进度反馈、无日志落点，卡住不可诊断。

## 3. 目标

- **列盘循环零外部 exec**：枚举 + 类型探测一次性批量完成并预计算，列盘循环纯 shell 显示。
- **超时兜底**：所有 lsblk/blkid 外部调用包 `timeout`，单次挂起 3s 返回空 → 盘标 UNK/跳过并告警，不拖死菜单。
- **进度反馈 + 日志增强**：列盘前打印 `Scanning disks...`；枚举结果落日志；卡住可从日志定位。
- 版本 v1.2.0 → **v1.3.0**（次版本 +1：修复 + 结构优化）。

## 4. 非目标 / 反目标

- 非目标：不改清除算法（umount→wipefs→partprobe→验证）与白名单；不改交互契约（默认全选/排除/YES/0 退出）；不做并行化（POSIX/ash 无可靠并行，且复杂化收益低）。
- 反目标：
  - 列盘循环内不得出现任何外部命令调用（含 awk/printf 外部版）——必须纯 shell + 预计算数据。
  - 超时兜底不改变"盘标 UNK 也可勾选"语义（类型仅提示）。
  - 不引入 bash 专属语法（保持 POSIX/ash）。

## 5. 设计

### 5.1 批量类型探测（替代逐盘 dw_is_system_disk）

- 新增 `dw_scan_system_disks()`（lib.sh）：**一次 lsblk**（`-o NAME,TYPE,MOUNTPOINT,PKNAME,PARTTYPENAME,PARTFLAGS` 全盘表）+ **一次 blkid**（带设备名格式 `blkid -c /dev/null -o full`——util-linux blkid 无参 `-s TYPE -o value` 只输出 TYPE 值列表不带设备名，无法映射分区→父盘，故用 `-o full` 输出 `设备: TYPE="xxx"` 逐行，awk 归并到父盘）→ 输出"每个 disk 的类型码"（0=数据盘 1=系统盘 2=未知），供 menu 查表。
  - 探测口径与 dw_is_system_disk 一致（GPT ESP/EFI 名含 EFI、MBR 0x80、ntfs、全未知→UNK）。
  - **批量超时取舍（builder-check 裁定）**：timeout 一次杀整个进程，故障盘之外盘的类型一并丢失 → 接受"批量超时 → 全部盘标 UNK"（类型仅提示不影响清除；零 exec 目标的必然取舍），H3 断言相应调整。
- menu 列盘循环内用查表替代 `dw_is_system_disk` 调用（循环内零 exec）。

### 5.2 列盘字段解析批量化

- `disk_display_fields` 保持但改为**一次 awk 处理全部行**（新 `dw_format_disk_lines()`：输入全部枚举行，输出全部"设备|容量|型号|TRAN|类型"行）→ menu 循环内只做 shell 字符串切分（`${var%%|*}`），零外部命令。

### 5.3 超时兜底（timeout 接缝，覆盖全部只读探测）

- 新增接缝 `TIMEOUT_BIN="${TIMEOUT_BIN:-timeout}"`。
- **全部只读探测包 `"$TIMEOUT_BIN" 3 <cmd>`（builder-check 裁定）**：dw_enum_disks（lsblk）、dw_scan_system_disks（lsblk+blkid）、dw_disk_mountpoints（清除阶段逐盘 lsblk）、init 的日志介质探测（dw_mount_log_media 的 blkid/lsblk）——统一"只读探测全部超时兜底"。超时/失败返回空。
- **枚举超时降级语义（builder-check 裁定）**：`dw_enum_disks` 超时/失败返回空时，menu **不得**走"仅启动介质"退出路径——打印 `ERROR: disk scan timed out or failed`，自动重试一次；仍失败打印错误并提示可安全重启（不误判"仅启动介质"）。
- 清除操作（umount/wipefs/partprobe）**不加 timeout**（破坏性操作不能半途超时中断）。
- initramfs 需要 busybox timeout（busybox 已含 timeout applet；build 无需新增）。

### 5.4 进度反馈 + 日志增强

- menu 枚举后打印 `Scanning disks... (please wait)`（若批量探测耗时，用户看到提示而非假死）。
- `dw_enum_disks`/`dw_scan_system_disks` 完成后落日志（盘清单行数、每盘摘要）→ 卡住时日志可定位是枚举、探测还是显示。
- 保持屏幕全部用户可见行 ASCII（沿用 v1.2.0 约束）。

### 5.5 版本与打包

- `VERSION` 1.2.0 → **1.3.0**（保留 BOM 布局）；重新 build；qemu 冒烟复验（横幅 v1.3.0 + 列盘正常 + 虚拟盘 OK 行）。
- README：列盘性能/超时说明；§10 重测指引保持。

## 6. 测试计划（tests/，假件注入）

| 编号 | 场景 | 断言 |
|---|---|---|
| H1 | 列盘循环零 exec | menu 列盘典型流程的 cmds.txt **只含枚举/批量探测调用**（无逐盘 lsblk/blkid/awk）；列盘期间不出现新的外部命令 |
| H2 | 批量探测 | `dw_scan_system_disks` 用一次 lsblk + 一次 blkid 输出每盘类型；ESP 盘 SYS、ntfs SYS、无签名 DATA、探测不到 UNK |
| H3 | 超时兜底 | TIMEOUT_BIN=假件（返回 124）时：枚举/探测返回空 → 盘标 UNK、菜单仍显示其余盘、不挂死 |
| H4 | timeout 接缝 | TIMEOUT_BIN 指向假件时记录调用（`timeout 3 <cmd>`）；生产默认 timeout |
| H5 | 类型查表 | 与 dw_is_system_disk 口径一致（SYS/DATA/UNK 映射不变） |
| H6 | 进度/日志 | 枚举后屏幕含 `Scanning disks...`；日志含盘清单行 |
| 回归 | 既有 t1-t5 全部保持 PASS（交互契约不变；新增批量路径断言） | — |

## 7. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 批量 blkid 全盘仍可能挂起（某盘 I/O 阻塞） | 已包 timeout 3 兜底（H3）；且批量调用只一次，超时仅丢该盘类型（UNK），不丢整个菜单 |
| 一次 lsblk 全盘输出大（几十盘） | awk 一次处理，O(N)；列盘循环零 exec |
| busybox timeout 行为差异 | build 后 qemu 冒烟验证；测试用假件验证接缝 |
| 真机根因未 100% 坐实（挂点可能是 blkid 或 exec） | 三支柱齐下：即使挂点是"U 盘 exec 卡顿"，列盘循环零 exec 后循环内无命令可挂；即使挂点是 blkid I/O，timeout 兜底（H3） |

## 8. 文档与交付

- README：列盘批量探测与超时说明。
- v1.3.0 重打包 + qemu 冒烟（列盘正常 + 虚拟盘 OK）。
- **交付后重测指引（用户执行）**：v1.3.0 → IPMI KVM 进 → 观察 `Scanning disks...` 后列表出现 → 全选 → YES → 逐盘 OK/FAIL → 重启后 FirPE 复查。若仍卡，日志（本次已增强）定位。

## 9. 留给实现者的决定 / 设计者已定

- 设计者已定：批量探测（一次 lsblk + 一次 blkid 全盘）；timeout 3 兜底（仅只读探测，不清除操作）；`Scanning disks...` 提示；v1.3.0；列盘循环零 exec。
- 留给实现者：批量 awk 的具体字段归并实现；类型码表格式；测试断言细节；README 文案。
