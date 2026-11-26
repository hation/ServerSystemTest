# Task 7 report — v1.5.7 去掉设备重试扫描（U 盘 D 状态卡点）+ 菜单阶段全进度

## 状态：DONE

commit：`cebce11`（main，6 files changed, 42 insertions(+), 19 deletions(-)）
```
fix(diskwipe-iso): 去掉设备重试扫描（U 盘枚举后重试 mdev 触发 D 状态 I/O 阻塞致卡死）+ menu/lib 加 kmsg 进度 + 写日志前补建 U 盘节点；v1.5.7 重打包
```

## 改动 diff

### 1. `diskwipe-iso/src/init`（POSIX/ash、行尾与基线一致、中文注释）

- 头注释更新：`→ sleep 2 等待设备稳定 → 重试循环（每轮 mdev -s 补建节点）→ exec menu.sh`
  改为 `→ sleep 3 等待设备稳定（v1.5.7：去掉重试 mdev 轮询）→ exec menu.sh`；新增 v1.5.7 语义段
  （真机 U 盘枚举后重试 mdev 触发 U 盘 I/O 阻塞——内核 D 状态不可中断、用户态 timeout 无效——
  致 init 卡死、menu 永不启动；U 盘节点改由 menu 退出写日志前 dw_save_log_to_usb 内补建）。
- 设备重试扫描段（原 `sleep 2` + `for dwtry in 1 2 3; do timeout 5 mdev -s; sleep 2; done`）整段
  替换为（与 brief 原文一致）：
  ```sh
  # 4) 等待设备稳定（v1.5.7：去掉设备重试扫描（mdev -s 轮询）——真机 U 盘枚举后重试
  #    mdev 触发 U 盘 I/O 阻塞（内核 D 状态，用户态 timeout 无效）致 init 卡死。改为仅
  #    sleep 等待设备稳定；U 盘设备节点由 menu 退出写日志前 dw_save_log_to_usb 内
  #    mdev -s 补建（失败降级）。
  dw_progress "device settle wait (sleep)"
  sleep 3
  ```

### 2. `diskwipe-iso/src/lib.sh`（POSIX/ash）

- 顶部（接缝变量前）新增共用 kmsg 进度函数（与 init 相同定义，供 init/menu/lib 共用）：
  ```sh
  dw_progress() { echo "diskwipe-init: $*" > /dev/kmsg 2>/dev/null; }
  ```
- `dw_save_log_to_usb` 开头（枚举候选分区前）新增（`TIMEOUT_BIN` 接缝已存在，mdev 失败静默走既有降级）：
  ```sh
  # v1.5.7：清盘完成后写日志前补建 U 盘设备节点（init 已不再重试 mdev；此时若 mdev
  # 卡住属可接受——清盘已完成，下方降级提示抄录后断电）
  "$TIMEOUT_BIN" 5 mdev -s 2>/dev/null
  ```

### 3. `diskwipe-iso/src/menu.sh`（只加进度行，交互逻辑/输出内容零改动）

- 入口（`. lib.sh` 之后、横幅之前）：`dw_progress "menu.sh started"`
- 关键阶段（while 循环内）：
  - 枚举前：`dw_progress "enumerating disks (lsblk)"`
  - 批量类型探测前：`dw_progress "scanning disk types (blkid)"`
  - 清盘执行前：`dw_progress "wiping disks"`
- `dw_log_finish`（写 U 盘前）：`dw_progress "saving log to USB"`

### 4. `diskwipe-iso/VERSION`：`1.5.6` → `1.5.7`

### 5. `diskwipe-iso/tests/t3_init.sh`（适配重试轮去掉）

- I1：`check_cmd_count 'mdev -s' 4`（首扫+3 轮重试）→ `1`（v1.5.7 去掉重试轮）；注释同步；
  新增 `check_kmsg 'diskwipe-init: device settle wait (sleep)'`。
- I2：`check_cmd_count 'mdev -s' 4` → `1`（模块失败后仍只首扫）。
- 头注释 `sleep 2` → `sleep 3（v1.5.7：去掉重试 mdev 轮询）`。

### 6. `diskwipe-iso/tests/t4_log.sh`（适配 lib 写日志 mdev）

- L3（成功路径）新增假 mdev（记录调用到 cmds.txt）+ 断言
  `check_cmds 'mdev -s' '写日志前应先补建 U 盘设备节点（mdev -s）'`；头注释补 v1.5.7 适配说明。

## 构建关键行（WSL Kylin 模式）

产物：`diskwipe-iso/output/diskwipe-v1.5.7.iso`（39M，output/ 已 gitignore 不入库）
- `内核模式：kylin`；`使用内核：4.19.90-89.11.v2401.ky10.x86_64`
- `Kylin 模块提取：白名单 + 依赖链共 26 个 .ko.xz`；`VERSION → /diskwipe.version（1.5.7）`；`initrd.img：5.0M`
- isoinfo 校验全部通过（`initrd 内 /diskwipe.version = 1.5.7`、`src 四脚本 dash -n 语法 0 错误`、
  26 个未压缩 .ko、Kylin 4.19 版本串、双 console 参数、BOOTX64.EFI PE 有效）

注：本机 Git Bash 的 PATH 解析不了无扩展名 `wsl`（MSYS 对 WindowsApps 别名解析失败，
build.sh 检测 `wsl -l -v` 失败）——用 `tmp/build-v157.sh` 等价执行 build.sh 内逻辑
（`wsl.exe` 完整路径 + WSL 路径显式传参），构建流程与结果一致。

## 验证断言输出

### A（qemu UEFI -vga std，tmp/dw-smoke-uefi-v157.sh）→ PASS（28 断言全过）
- v1.5.7 新增 kmsg 进度行全部出现（serial 输出带内核时间戳）：
  `device settle wait (sleep)` / `menu.sh started` / `enumerating disks (lsblk)` /
  `scanning disk types (blkid)` / `wiping disks` / `saving log to USB`
- 全流程：Linux version 4.19.90 / RAMDISK: / DiskWipe Tool 1.5.7 / 三盘 SYS-DATA-UNK /
  OK x3 / Exited. / Log kept in memory / Cleanup log saved to USB（USB 日志 version 1.5.7）
- 无 ERROR / 无 Only boot media；显卡循环无非 ast 驱动

### B（qemu UEFI -vga none，tmp/novid-v157.sh）→ PASS
- serial 兜底：Booting in blind mode 打印（允许）但内核照常启动
- Linux version 4.19.90 / RAMDISK: / Run /init
- kmsg 进度行：loading module / Disk driver modules loaded / Device nodes scanned /
  **device settle wait (sleep)** / **menu.sh started** 全出现

### C（qemu BIOS isolinux，tmp/dw-smoke-v157.sh）→ 27 断言全 PASS（21 项回归 + 6 项 v1.5.7 新增）
- ISOLINUX 6.04 / Loading /boot/vmlinuz... ok / Loading /boot/initrd.img...ok /
  Linux version 4.19.90 / RAMDISK: / 1.5.7 横幅 / Scanning / Disks found 3 /
  SYS×DATA×UNK / OK x3 / Exited / Log kept in memory / Cleanup log saved to USB /
  no GNU GRUB / no ERROR / no Only boot media / no No writable log media
- v1.5.7 新增：device settle wait / menu.sh started / enumerating disks / scanning disk
  types / wiping disks / saving log to USB 全部出现；USB 数据区日志落盘成功
  （证明写日志前 mdev -s 补建 U 盘节点生效）

### tests t1-t6 回归（Git Bash，bash diskwipe-iso/tests/run-all.sh）→ 全部 ALL PASS
- t3_init：`设备扫描应仅执行 1 次（v1.5.7 去掉重试轮）`、`kmsg 设备稳定等待进度行` 等新增断言 PASS
- t4_log：`写日志前应先补建 U 盘设备节点（mdev -s）` PASS
- 全量汇总：通过 77 项（t6 段），失败 0 项；run-all.sh 退出 0

验证脚本留档：`tmp/dw-smoke-uefi-v157.sh`、`tmp/novid-v157.sh`、`tmp/dw-smoke-v157.sh`
（输出：`tmp/dw-smoke-uefi-v157.out(.clean)`、`tmp/novid-v157.out`、`tmp/dw-smoke-v157.out(.clean)`、
`tmp/dw-smoke-v157-keylines.txt`、`tmp/build-v157.log`、`tmp/build-v157.sh`）。

## 一行测试摘要

qemu A（UEFI -vga std 全流程+kmsg 六进度行）、B（-vga none serial）、C（BIOS 27 项）+ tests t1-t6（77 项）全部 PASS；iso 已重打包 v1.5.7。

## concerns

1. **qemu B 尾部出现内核 panic「Attempted to kill init! exitcode=0x00000000」**：无盘场景下
   menu 打「Only boot media found」后 exit 0 → PID 1（init exec 的 menu.sh）退出 → 内核 panic。
   与 v1.5.6 行为一致（既有无盘路径语义，非本次引入），novid 断言只看内核启动/init 流程/kmsg
   进度，判定 PASS。
2. **构建入口**：本环境 Git Bash 的 `wsl`（无扩展名）PATH 解析失败（MSYS/WindowsApps 别名问题），
   用 `wsl.exe` 完整路径包装等价执行 build.sh 内逻辑（`tmp/build-v157.sh`），构建产物与校验结果
   与 build.sh 一致；此问题不影响生产构建脚本本身。
3. **行尾**：与 task-6 一致——仓库 core.autocrlf=true，工作副本 CRLF/提交内容 LF，本次保持基线
   风格未改；busybox ash（A/B/C 全流程）与 Git Bash 测试均正常。
4. **U 盘节点补建的残余风险**：若真机清盘完成后 U 盘本身 I/O 阻塞（内核 D 状态），
   `dw_save_log_to_usb` 开头的 `mdev -s` 仍可能挂住（此时清盘已完成，属可接受，降级提示
   「抄录后断电」兜底）——这是 brief 明示的可接受行为。
