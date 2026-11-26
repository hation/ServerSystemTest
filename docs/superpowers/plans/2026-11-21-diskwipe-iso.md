# diskwipe-iso 可启动 ISO 硬盘恢复工具 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建一个可启动 ISO（Linux 启动环境），开机自动列出所有硬盘（默认全选），输入 `YES` 二次确认后一键 `wipefs` 清分区表+文件系统签名，把硬盘恢复为"未初始化"；Windows 本机经 WSL 一键构建双引导 iso。

**Architecture:** 独立工具目录 `diskwipe-iso/`：`src/`（POSIX/ash 兼容脚本：lib.sh 共享逻辑、wipe.sh 清除、menu.sh 交互、init 启动）+ `build.sh`/`build-lib.sh`（WSL 内 apt 装包→组装 initramfs→grub-mkrescue 生成 BIOS+UEFI 双引导 iso）+ `tests/`（假命令注入单测）+ README/VERSION。测试全部用假件隔离，绝不触碰本机真实块设备。

**Tech Stack:** bash（POSIX/ash 兼容，initramfs 运行时仅 busybox ash）、busybox（静态）、util-linux（wipefs/lsblk 动态+ldd 依赖）、GRUB2（grub-mkrescue）、WSL Ubuntu-24.04（构建）、xorriso/mtools/cpio

**Spec:** [2026-11-21-diskwipe-iso-design.md](../specs/2026-11-21-diskwipe-iso-design.md)

## Global Constraints

- 全部 src 脚本必须 **POSIX/ash 兼容**（initramfs 运行时只有 busybox ash；禁止 bash 专属语法如 `[[ ]]`/数组下标越界防护外的 bash 特性）；LF 行尾。
- **测试绝不触碰本机真实块设备**：全部假命令注入（LSBLK_BIN/BLKID_BIN/WIPEFS_BIN/UMOUNT_BIN 接缝变量），wipefs 假件只记录调用参数到 cmds.txt、绝不执行真实 wipefs；测试在临时目录（mktemp）运行。
- 设备白名单：仅允许 `sd[a-z]`/`nvme[0-9]n[0-9]`/`vd[a-z]`/`mmcblk[0-9]` 形态；排除 `TRAN=usb` 与 `sr*`/`loop*`/`ram*`。
- 清除动作固定：先 umount 该盘全部子树挂载点 → `wipefs -a <整盘>` → `wipefs -n` 验证（输出空=未初始化）；任一失败该盘标失败、其他盘继续、不误报成功。
- 交互固定：列盘（编号/设备/容量/型号/类型标注）→ **默认全选**、输入编号可排除、回车=全部 → 打印将清除清单 → 输入大写 `YES` 才执行 → 结果 → 循环；0 退出；**不自动关机**。
- 类型标注：有 OS 迹象分区（vfat+esp、ntfs、ext4/xfs/btrfs+boot 标志）→ "系统盘"；无 → "数据盘"；判定失败 → "未知"；仅提示不影响可勾选。
- 构建：WSL 内 `apt-get install -y busybox-static xorriso mtools grub-pc-bin grub-efi-amd64-bin linux-image-generic`；grub.cfg 内核参数含 `console=tty0 console=ttyS0,115200n8`；grub-mkrescue 生成双引导 iso 到 `diskwipe-iso/output/diskwipe-<版本>.iso`；isoinfo 校验。
- 版本：`diskwipe-iso/VERSION` v1.0.0；iso 名 `diskwipe-v1.0.0.iso`。
- 模块白名单：`ahci libahci libata nvme nvme-core mpt3sas megaraid_sas virtio_blk virtio_pci xhci_pci sd_mod scsi_mod`。
- 工具目录 `diskwipe-iso/` 为正式交付工具（tests 入库），与 `.superpowers/` 临时测试区无关。

## Review Focus

- 假 lsblk 输出含**白名单外设备名**（如 `sdb1` 分区、`loop0`、异常名）→ 枚举拒绝并跳过，不清除（Task 1 测试）。
- **型号列含空格/为空**（SAS 卡盘 MODEL 空）→ 列表不崩、显示"未知型号"（Task 1 测试）。
- 排除输入**含非法字符/非数字**（如 `1,2,x`、空串）→ 忽略非法项、保留合法项、空串=全部（Task 2 测试）。
- **串口 SOL 控制台**下交互（无真实 tty）→ 读 stdin 写 /dev/console，不依赖 tty 特定行为（Task 2/3 用管道喂 stdin 测试 + 真机清单）。
- **构建失败路径**（WSL 无包/grub-mkrescue 报错）→ 明确报错信息与退出码，不静默（Task 4 验证）。

---

### Task 1: src/lib.sh + src/wipe.sh（核心逻辑）与清除单测

**Files:**
- Create: `diskwipe-iso/src/lib.sh`
- Create: `diskwipe-iso/src/wipe.sh`
- Create: `diskwipe-iso/tests/lib.sh`（假件注入骨架）
- Create: `diskwipe-iso/tests/t1_wipe.sh`
- Create: `diskwipe-iso/tests/run-all.sh`

**Interfaces:**
- Consumes: 无（本任务自含）
- Produces（后续任务依赖的签名）：
  - `dw_enum_disks` → 每行 `设备 容量 型号 TRAN 挂载点`（挂载点逗号拼接；白名单过滤；排除 usb/sr*）
  - `dw_disk_mountpoints <dev>` → 该盘子树全部挂载点，每行一个（无挂载输出空）
  - `dw_is_system_disk <dev>` → 0=数据盘/1=系统盘/2=未知（OS 迹象判定）
  - `dw_wipe_disk <dev>` → 0=已恢复未初始化/非0=失败（umount 全部→wipefs -a→wipefs -n 验证，逐步）
  - 接缝变量：`LSBLK_BIN`/`BLKID_BIN`/`WIPEFS_BIN`/`UMOUNT_BIN`（默认系统命令）；`dw_dev_ok <dev>`（白名单校验，供 wipe.sh 与测试复用）

- [ ] **Step 1: 建 tests/lib.sh 假件骨架（复制 hdd-align-field 风格并改造）**

  假件（全部经接缝变量注入，wipefs 假件只记录）：`lsblk` 按 `$ROOT/lsblk.table` 输出；`blkid` 按 `$ROOT/blk.type` 返回（ESP→`vfat`、Windows→`ntfs`、Linux→`ext4`、无→空）；`wipefs -a <dev>` 把 `wipefs -a <dev>` 追加 `$ROOT/cmds.txt`（`$ROOT/wipefs.afail` 存在时返回 1）；`wipefs -n <dev>` 按 `$ROOT/wipefs.sigs` 输出；`umount <mp>` 记录（`$ROOT/umount.failmp` 命中时返回 1）。全部命令可执行脚本，PATH 前置。

- [ ] **Step 2: 写 t1_wipe.sh 用例并跑 fail 阶段**

  用例（每个 `setup_tmp; install_fakes; 写描述文件; run_wipe <args>; check_*`）：

  | 编号 | 场景 | 断言 |
  |---|---|---|
  | W1 | 枚举：sda(esp+sda1)→系统盘、sdb(无分区)→数据盘、sdc(usb)、sr0、sdd 分区 sdd1 | `dw_enum_disks` 只含 sda/sdb/sdd，排除 sdc/sr0/sdd1；sda 类型=系统盘、sdb=数据盘 |
  | W2 | 白名单外设备 `loop0`/`sdb1` 混入 lsblk 输出 | 枚举拒绝，不出现、不清除 |
  | W3 | 型号列含空格/为空 | 列表显示原型号或"未知型号"，不崩 |
  | W4 | `dw_wipe_disk sda`（sda1 挂 /mnt） | cmds.txt 依次含 `umount /mnt`、`wipefs -a /dev/sda`；`wipefs -n` 后输出"已恢复未初始化"；退出 0 |
  | W5 | `dw_wipe_disk sdb`（无挂载） | 无 umount；直接 `wipefs -a /dev/sdb`；退出 0 |
  | W6 | umount 失败（umount.failmp 命中） | 该盘失败：无 `wipefs -a`、输出失败原因、退出非 0 |
  | W7 | wipefs -a 失败（wipefs.afail） | 该盘失败、不执行后续验证、退出非 0 |
  | W8 | wipefs -n 仍有残留（wipefs.sigs 非空） | 该盘失败（残留）、退出非 0 |
  | W9 | 逐盘独立：sda 失败 + sdb 成功 | sdb 仍被清除；汇总输出失败盘清单 |
  | W10 | 类型判定失败（blkid 无输出） | 类型="未知"，不影响可清除 |

  运行 `bash tests/run-all.sh`，预期 FAIL（lib.sh/wipe.sh 不存在）。

- [ ] **Step 3: 实现 src/lib.sh（dw_enum_disks / dw_disk_mountpoints / dw_is_system_disk / dw_dev_ok）**

  按上述接口签名；lsblk 列解析用 awk（按 NAME 列定位，MODEL 含空格取剩余原文）；OS 迹象用 `$BLKID_BIN -s TYPE -o value <分区>` + 分区标志（`lsblk -no PARTFLAGS` 或从 table 判定，实现者可定）。

- [ ] **Step 4: 实现 src/wipe.sh**

  用法 `wipe.sh <dev...>`：逐盘 `dw_wipe_disk`，每盘打印 `✓ 已恢复未初始化` 或 `✗ <原因>`；有失败盘退出 1。白名单校验失败打印原因跳过。

- [ ] **Step 5: 跑 t1_wipe.sh 全绿**

  `bash diskwipe-iso/tests/run-all.sh` → 全部 PASS、退出 0。

- [ ] **Step 6: Commit**

  ```bash
  git add diskwipe-iso/src diskwipe-iso/tests
  git commit -m "feat(diskwipe-iso): 核心逻辑 lib.sh/wipe.sh（枚举/标注/umount+wipefs+验证）与假件单测"
  ```

---

### Task 2: src/menu.sh（交互菜单）与交互单测

**Files:**
- Create: `diskwipe-iso/src/menu.sh`
- Create: `diskwipe-iso/tests/t2_menu.sh`
- Modify: `diskwipe-iso/tests/run-all.sh`（纳入 t2）

**Interfaces:**
- Consumes: Task 1 的 `dw_enum_disks`、`dw_is_system_disk`、`wipe.sh <dev...>`
- Produces: 交互入口 `menu.sh`（列盘→默认全选→排除编号→YES 确认→调 wipe.sh→循环；0 退出；输入大写 `YES` 才执行）

- [ ] **Step 1: 写 t2_menu.sh 用例并跑 fail 阶段**

  用例（用 `printf '...\n' | bash src/menu.sh` 喂 stdin，断言 stdout 与对 wipe.sh 的调用）：

  | 编号 | 场景 | 断言 |
  |---|---|---|
  | M1 | 两盘 sda/sdb + sdc(usb) | 列表含 sda/sdb、不含 sdc；sda 标"系统盘"、sdb 标"数据盘" |
  | M2 | 回车（默认全选）→ `YES` | 调用 wipe.sh 且参数含 sda sdb；输出确认清单 |
  | M3 | 输入 `1` 排除 → `YES` | 只调用 wipe.sh sdb |
  | M4 | 输入 `YES` 以外的值（y/no/空） | 不执行清除，回到菜单或退出（不出现 wipe.sh 调用） |
  | M5 | 排除输入 `1,2,x`（含非法） | 忽略 x，排除 1、2；合法项生效 |
  | M6 | 无盘可清（仅 usb+光驱） | 提示"仅发现启动介质"、退出、无 wipe.sh 调用 |
  | M7 | 清除后循环：再次列出（盘已清后状态刷新） | 可继续选择或 0 退出 |
  | M8 | 输入 `0` 退出 | 打印退出提示（可断电/重启），退出 0 |

  运行 `bash tests/run-all.sh`，预期 t2 FAIL。

- [ ] **Step 2: 实现 src/menu.sh**

  按 Review Focus 的交互契约：读 stdin 写 stdout；`YES` 严格大写匹配；非法输入忽略；默认全选=排除列表为空时全部。

- [ ] **Step 3: 跑 t2_menu.sh 全绿**

  `bash diskwipe-iso/tests/run-all.sh` → t1+t2 全 PASS。

- [ ] **Step 4: Commit**

  ```bash
  git add diskwipe-iso/src/menu.sh diskwipe-iso/tests
  git commit -m "feat(diskwipe-iso): 交互菜单 menu.sh（列盘/默认全选/排除/YES确认/循环）与单测"
  ```

---

### Task 3: src/init（initramfs 启动脚本）

**Files:**
- Create: `diskwipe-iso/src/init`
- Create: `diskwipe-iso/tests/t3_init.sh`
- Modify: `diskwipe-iso/tests/run-all.sh`（纳入 t3）

**Interfaces:**
- Consumes: Task 2 的 `menu.sh`（init 最后 `exec menu.sh`）
- Produces: `src/init`（挂载 /proc /sys /dev → busybox modprobe 白名单模块 → mdev -s → sleep 2 → exec menu.sh；任一步失败打印错误并停留 shell）
- 常量：`DRIVE_MODULES="ahci libahci libata nvme nvme-core mpt3sas megaraid_sas virtio_blk virtio_pci xhci_pci sd_mod scsi_mod"`

- [ ] **Step 1: 写 t3_init.sh（用假 modprobe/mdev/mount 在 stub 环境跑 init）并跑 fail 阶段**

  | 编号 | 场景 | 断言 |
  |---|---|---|
  | I1 | 正常：假 mount/modprobe/mdev 全部成功 | 输出含挂载 /proc /sys /dev；`modprobe` 调用覆盖 DRIVE_MODULES 全部模块名；最后执行 menu.sh（假 menu.sh 打标记） |
  | I2 | modprobe 某模块失败 | 不静默：打印错误并停留 shell（不 exec menu.sh，便于现场诊断） |

  运行 `bash tests/run-all.sh`，预期 t3 FAIL。

- [ ] **Step 2: 实现 src/init（POSIX/ash）**

  按接口；**任一步失败（挂载或模块加载）打印错误并停留 shell（不 exec menu.sh）**，与设计 §6.3 一致；全成功后 `exec menu.sh`。

- [ ] **Step 3: 跑 t3_init.sh 全绿 + ash -n 语法校验**

  `bash diskwipe-iso/tests/run-all.sh` 全 PASS；`ash -n src/init src/menu.sh src/wipe.sh src/lib.sh`（Git Bash 内用 `busybox ash -n` 或 WSL `dash -n`）0 错误。

- [ ] **Step 4: Commit**

  ```bash
  git add diskwipe-iso/src/init diskwipe-iso/tests
  git commit -m "feat(diskwipe-iso): initramfs 启动脚本 init（挂载/模块白名单/mdev/exec menu）"
  ```

---

### Task 4: build.sh + build-lib.sh（WSL 一键构建）与本机构建验证

**Files:**
- Create: `diskwipe-iso/build.sh`
- Create: `diskwipe-iso/build-lib.sh`
- Modify: `diskwipe-iso/VERSION`（内容 `1.0.0`）
- Create: `diskwipe-iso/.gitignore`（忽略 `output/`）

**Interfaces:**
- Consumes: Task 1-3 全部 src；WSL Ubuntu-24.04（已实测 DNS/网络/sudo 免密可用）
- Produces: `build.sh`（Windows 入口：检测 WSL → 调用 WSL 内构建）→ `diskwipe-iso/output/diskwipe-v1.0.0.iso`（双引导）；isoinfo 校验通过

- [ ] **Step 1: 写 build-lib.sh 的 WSL 内构建步骤（幂等）**

  `wsl 内`：`apt-get update` + `apt-get install -y busybox-static xorriso mtools grub-pc-bin grub-efi-amd64-bin linux-image-generic`（幂等：已装跳过）→ 组装 `rootfs/`：拷贝 `/bin/busybox`（静态）、`wipefs`/`lsblk`（`ldd` 收集 .so 依赖）、`/boot/vmlinuz-*`、`/lib/modules/<ver>/` 白名单模块 + `depmod -b rootfs`、src 四个脚本 → `cpio` 打包 initrd.img → 写 `boot/grub/grub.cfg`（menuentry：`linux /boot/vmlinuz console=tty0 console=ttyS0,115200n8` + `initrd /boot/initrd.img`）→ `grub-mkrescue -o output/diskwipe-v1.0.0.iso -- -V DISKWIPE rootfs/` → `isoinfo -i` 校验三个关键文件存在。
  关键点（实现者须处理）：grub-mkrescue 需要 mtools（mformat 生成 EFI 镜像）；模块提取用 `find`+依赖（或直接整个 `kernel/drivers/{ata,nvme,scsi/mpt3sas,megaraid,virtio}` 目录拷贝 + depmod）；initrd 用 `find | cpio -o -H newc | gzip`；util-linux 动态二进制 + `.so` 依赖（`ldd` 解析复制到 `lib/` 并设置 `LD_LIBRARY_PATH` 或按原路径布局）。

- [ ] **Step 2: 写 build.sh（Windows 入口 + 错误提示）**

  检测 `wsl -l -v` 含 Ubuntu；不可用 → 打印安装指引退出 1；可用 → `wsl -e bash -c '<build-lib 构建函数>'`；任何失败步骤输出明确错误并退出非 0（不静默）。

- [ ] **Step 3: 本机跑通构建并校验**

  运行 `bash diskwipe-iso/build.sh`（Git Bash）。预期：生成 `diskwipe-iso/output/diskwipe-v1.0.0.iso`；`isoinfo -i <iso> -l` 含 `boot/grub/grub.cfg`、`boot/vmlinuz`、`boot/initrd.img`；grub.cfg 内容含两个 console 参数；`ash -n`/`dash -n` 对 src 全部脚本 0 错误。记录构建产物信息于报告（构建约需数分钟下载）。

- [ ] **Step 4: Commit**

  ```bash
  git add diskwipe-iso/build.sh diskwipe-iso/build-lib.sh diskwipe-iso/VERSION diskwipe-iso/.gitignore
  git commit -m "feat(diskwipe-iso): WSL 一键构建 build.sh（组装 initramfs + grub-mkrescue 双引导 iso + isoinfo 校验）"
  ```

---

### Task 5: README.md + 收尾验证

**Files:**
- Create: `diskwipe-iso/README.md`

**Interfaces:**
- Consumes: Task 4 的实际 CLI（`bash build.sh`）与产物（`output/diskwipe-v1.0.0.iso`）

- [ ] **Step 1: 写 README.md**

  内容：工具用途与安全声明（只清分区表+签名、不碰数据块、不清 SMART）；构建（`bash build.sh`，需 WSL+网络，产物路径）；写入 U 盘（dd/Rufus 步骤）；真机冒烟清单（列盘→全选→YES→lsblk 验证无分区）；驱动兜底（`EXTRA_MODULES_DIR` 从 Kylin 拷 vmlinuz/模块的替换路径）；交互说明（默认全选/排除/YES/0 退出）；测试运行方式（`bash tests/run-all.sh`）。

- [ ] **Step 2: 交叉核对 README 与真实 CLI/产物**

  逐条核对 README 命令与 build.sh 实际行为、iso 产物文件名一致。

- [ ] **Step 3: 全量回归**

  `bash diskwipe-iso/tests/run-all.sh` 全 PASS；`ash -n`/`dash -n` 全部 src 脚本 0 错误；`git status` 仅 diskwipe-iso/ 相关变更。

- [ ] **Step 4: Commit**

  ```bash
  git add diskwipe-iso/README.md
  git commit -m "docs(diskwipe-iso): README 使用/构建/真机冒烟/兜底说明"
  ```
