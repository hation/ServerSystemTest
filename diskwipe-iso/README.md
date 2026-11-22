# diskwipe-iso：一键把硬盘恢复为「未初始化」的可启动 ISO 工具

- 版本：v1.4.1（`VERSION` 文件；iso 文件名含版本）
- 定位：替代「FirPE + DiskGenius 逐盘删分区」的现场流程——从 U 盘启动后自动进入干净终端菜单，列出全部硬盘（默认全选），大写 `YES` 二次确认后一键清除分区表与文件系统签名，硬盘**秒级**恢复为「未初始化」。无图形界面、无「保存更改」中间步骤、无界面干扰。**全部屏幕输出为英文（ASCII）**：init 启动提示、菜单、每盘结果在无中文字体的终端（IPMI 虚拟 KVM / 串口 SOL）上完全可读，无乱码。**v1.4.1 起内核可选双模式**：默认自动检测 `kylin-src/` 使用 **Kylin 4.19 内核**构建（解决 Ubuntu 内核与该海光服务器 USB 栈不兼容导致启动卡死），亦可显式指定 WSL Ubuntu generic 内核。

## 1. 工具用途与安全边界

**用途**：把压测服务器上全部（或部分）硬盘恢复为「未初始化」状态——清除分区表 + 盘内全部文件系统/RAID/LVM 签名，供下次重建分区或交接使用。

**清除强度（三条边界，务必知悉）**：

| 边界 | 说明 |
|---|---|
| 只清分区表 + 签名 | 对整盘执行 `wipefs -a`：清 GPT/MBR 分区表签名与盘内全部 fs/raid/PV 签名；随后**立即 `partprobe`** 刷新内核分区视图（失败仅 `WARN:` 提示、不影响该盘结论，重启后同样生效），再以 `wipefs -n` 验证（输出为空 = 已未初始化） |
| **不清数据块** | 不覆盖、不写零、不做安全擦除——数据块原文仍在盘上，只是分区表与签名被清；如需彻底抹除数据请另做安全擦除 |
| **不清 SMART** | `wipefs` 只写块设备的签名区，**不读写 SMART 属性**——盘的通电时间、通电次数等统计保持不变 |

**其他安全属性**：

- 运行时**完全离线**（不依赖网络；仅构建时需要网络）。
- 操作**不可恢复**：分区表与签名一经清除无法复原，执行前请确认目标盘。
- 启动介质保护：启动 U 盘（`TRAN=usb`）与光驱（`sr*`）**硬排除**，绝不误清；设备名有代码层白名单校验（`sd[a-z]`/`sd[a-z][a-z]`、`nvme` 多位数字、`vd[a-z]`、`mmcblk` 多位数字——支持 27+ 块盘，排除 `loop*` / `ram*` / `sr*`）。
- 不自动关机：清完后由现场手动断电/重启（屏幕提示）。
- **屏幕全英文（乱码修复）**：v1.2.0 起 init 启动提示（挂载/模块加载/mdev/救援 shell）、菜单（标题/表头/类型/提示/确认/反馈）、每盘结果（`OK`/`FAIL`）全部为纯 ASCII——IPMI 虚拟 KVM（VGA→Linux vt console，无中文字体）、串口 SOL 均完全可读，不再出现方框乱码；中文仅保留在代码注释与本文档。引导菜单条目亦已 ASCII 化（`DiskWipe v1.2.0`）。

> **v1.2.0 白名单扩展**：白名单由 `sd[a-z]`/`nvme[0-9]n[0-9]`/`mmcblk[0-9]`（单数字、sdz 止）扩展为 `sd[a-z]`+`sd[a-z][a-z]`（支持 27+ 块盘，如 sdaa/sdab）、`nvme`/`mmcblk` 多位数字（如 nvme0n10、mmcblk10）——此类盘现在会正常列出并可清除；仍硬排除 `sr*`（光驱）、`loop*`、`ram*` 与 `TRAN=usb`（启动 U 盘）。
>
> **v1.3.0 列盘卡住修复（零 exec + 超时兜底 + 进度反馈）**：针对真机「进入菜单后界面卡死、列表一行未显示」问题——列盘循环改为**零外部命令**（枚举 + 类型探测 + 字段格式化各一次批量完成并预计算，循环内纯 shell 切分查表，无逐盘 lsblk/blkid/awk）；全部只读探测（枚举 lsblk、批量类型 lsblk+blkid、清除阶段挂载点、日志介质探测）统一包 `timeout 3` 兜底，单次探测挂起 3 秒即降级返回（不影响菜单）；枚举超时/失败打印 `ERROR` 并自动重试一次，**绝不误判「仅启动介质」退出**；列盘前打印 `Scanning disks... (please wait)` 进度提示、枚举结果落日志（`Disks found: N (...)`）——卡住时日志可直接定位阶段。清除操作（umount/wipefs/partprobe）**不加超时**（破坏性操作不能半途中断）。
>
> **v1.3.1 日志介质写超时降级（修复「U 盘写入卡死」）**：针对真机「屏幕只有内核日志、无菜单内容」问题（init 挂载日志介质后首次写卡死）——日志介质的**写操作**也纳入超时兜底：挂载后的可写性测试（写探测文件）包 `timeout 3`，U 盘写 I/O 阻塞 3 秒即放弃挂载、降级为仅屏幕模式；`dw_log` 写日志文件包 `timeout 2`，写入卡死即置 `LOG_DEGRADED` 降级为仅屏幕并一次性提示 `WARN: cleanup log media failed; log is screen-only`，**坏/慢 U 盘不再拖死菜单与清除**；清除阶段结果行在降级后仅屏幕显示（tee 不包超时以免 SIGPIPE 中断 wipe，由前置写失败触发降级）。正常 U 盘实时落盘行为不变。
>
> **v1.3.2 根治「init 阶段 U 盘 I/O 阻塞进不去菜单」**：针对真机「屏幕只有内核日志、菜单永不出现」问题（v1.3.1 的 timeout 兜底对内核 D 状态不可中断 I/O 无效——timeout 发 SIGTERM 杀不掉 D 状态进程，自身也挂起；dmesg `hub_event hogged CPU` 提示 USB 子系统异常）——**init 阶段改为零 U 盘 I/O**：不再挂载日志介质、不写测试、不做 U 盘探测（`dw_mount_log_media` 已删除），只保留 `mdev -s` 补建设备节点，**菜单必现**。清理日志改为**无条件写内存**（`/tmp/diskwipe-log`，initramfs rootfs 即 tmpfs，不受 U 盘 I/O 阻塞影响），0 退出时由 `dw_save_log_to_usb` **尽力写 U 盘一次**（枚举 U 盘可写分区 → `timeout 3` 挂载 → `cp` 日志 → 卸载）：成功打印 `Cleanup log saved to USB`；失败/无 U 盘打印 `WARN: could not write log to USB (disk I/O blocked or no USB); log kept in memory: <路径>`（可抄录日志后断电）。若退出时 U 盘 I/O 仍阻塞导致挂起——此时清理已完成，属可接受（提示断电）。
>
> **v1.3.3 批量类型探测 blkid 排除 U 盘（修复「menu 批量探测读 U 盘卡死」）**：针对 v1.3.2 真机「U 盘枚举完成（`sdb: sdb1 sdb2`）后菜单未出现、无任何输出」问题（U 盘 I/O 阻塞为内核 D 状态不可中断，timeout 的 SIGTERM 无效；dmesg `hub_event hogged CPU` 提示 USB 子系统异常）——`dw_scan_system_disks` 批量类型探测的 `blkid -c /dev/null -o full` 全盘扫描会读**所有**块设备（含启动 U 盘），U 盘 I/O 阻塞致 blkid 卡死、菜单枚举卡死。v1.3.3 改为：批量探测先经 `lsblk -o NAME,TYPE,TRAN,PKNAME -l`（同退出写 U 盘的 TRAN 枚举形态）过滤出**非 USB 白名单盘的分区列表**，`blkid` **只带这些分区作设备参数**（`-c /dev/null -o full /dev/sda1 /dev/sdb1 ...`）——**U 盘及其分区不在参数中，blkid 不读 U 盘**；无非 USB 盘分区时跳过 blkid。U 盘存在时菜单**立即出现**（qemu 冒烟含 USB 场景验证：vda/vdb/vdc + USB sda，三盘 OK）。类型判定口径（SYS/DATA/UNK）与启动介质保护不变。
>
> **v1.4.1 Kylin 内核构建模式（解决 Ubuntu 内核 USB 不兼容启动卡死）**：v1.3.x 系列已把「U 盘 I/O 阻塞」降级到可接受（菜单必现），但根因是 **Ubuntu 内核 xhci/USB 栈与该海光服务器 Microchip hub 不兼容**（dmesg `hub_event hogged CPU`）——该服务器 Kylin 4.19 内核系统运行正常。v1.4.1 起构建支持**内核双模式**：检测到 `diskwipe-iso/kylin-src/`（从目标 Kylin 服务器提取的内核材料，见 §3）即**自动使用 Kylin 4.19 内核**构建（`build.sh kylin` 强制 / `build.sh ubuntu` 强制 WSL Ubuntu generic 内核）；Kylin 模式从 `kylin-src/modules/<ver>/` 按 init 白名单 + `modules.dep` 依赖链提取驱动（ahci/libahci/libata、nvme/nvme-core/nvme-common、mpt3sas、megaraid_sas、virtio_blk、sd_mod、usb-storage/uas、nls_iso8859-1、vfat/fat），`.ko.xz` 构建期解压为 `.ko`（busybox modprobe 不支持 xz），`modules.dep/modules.alias` 拷入并 `sed` 改后缀；固件仅拷 `amd-ucode`（CPU 微码）；init 按 `uname -r` 含 `ky10` 自动切换白名单（Kylin 的 xhci_pci/usbcore/scsi_mod/virtio_pci 为内建无需加载，无 exfat/ntfs3 模块）。构建校验追加 Kylin 断言（vmlinuz strings 检出 `4.19.90` 版本串、关键模块为未压缩 `.ko`）；qemu 冒烟（Kylin 内核 + 虚拟 U 盘）菜单/列盘/清除/日志全过。**注意**：Kylin 4.19 无 exfat/ntfs3 模块，退出写日志 U 盘仅支持 vfat/ntfs（exfat U 盘日志写失败会降级为内存日志，不影响清理）。
>
> **注意**：启动介质保护仅针对 `TRAN=usb` 的 U 盘与 `sr*` 光驱；**若直接从硬盘启动本 iso，该硬盘不会被排除，会正常出现在可清列表**（属设计口径，勿在装有系统/数据的硬盘上启动后回车清盘）。

## 2. 目录结构

```
diskwipe-iso/
├── README.md            本说明
├── VERSION              版本号（当前 1.4.1，iso 文件名含版本；构建时拷入 initramfs 的 /diskwipe.version）
├── .gitignore           忽略构建产物 output/ 与 Kylin 材料解压目录 kylin-src/（不入库）
├── build.sh             Windows 一键构建入口（经 WSL Ubuntu 执行；可选参数 kylin|ubuntu|auto 指定内核模式）
├── build-lib.sh         构建函数库（apt 依赖→组装 initramfs→cpio→grub.cfg→grub-mkrescue→isoinfo 校验；内核双模式）
├── kylin-kernel-export.sh  在 Kylin 服务器一键提取内核材料（boot/modules/firmware → kylin-src-<日期>.tar.gz）
├── kylin-src-<日期>.tar.gz Kylin 内核材料包（构建材料入库；kylin-src/ 解压目录 git 忽略）
├── src/
│   ├── init             initramfs 启动脚本（挂载→白名单模块→mdev→exec menu.sh；失败进救援 shell；Kylin 内核自动切白名单）
│   ├── menu.sh          交互菜单（列盘/默认全选/排除/YES 确认/循环；0 退出）
│   ├── wipe.sh          清除入口（逐盘 umount→wipefs -a→wipefs -n 验证）
│   └── lib.sh           共享库（盘枚举/白名单/挂载点/类型标注/单盘清除）
├── output/              构建产物 diskwipe-v<版本>.iso（git 忽略，可随时由 build.sh 再生成）
└── tests/               离线测试（t1 核心逻辑 / t2 菜单 / t3 initramfs / t4 清理日志 / t5 真机修复验收 / t6 列盘批量探测与超时，共 355 项用例）
```

## 3. 构建（Windows 本机一键）

**前置条件**：

- WSL 已安装 **Ubuntu-24.04**（`build.sh` 会检测 `wsl -l -v` 是否含 Ubuntu；缺失时打印安装指引）；
- 需要**网络**（apt 下载构建依赖，首次耗时数分钟；重跑幂等，已装的包自动跳过）；
- WSL 内需 root 或免密 `sudo`（构建在 WSL 内 apt 安装依赖需要；指引见 build.sh 输出的安装步骤，含 `wsl --install -d Ubuntu-24.04` 与 `visudo` 追加 `NOPASSWD`）。

**命令**（在项目根目录执行）：

```bash
bash diskwipe-iso/build.sh          # 默认 auto：检测到 kylin-src/ 即用 Kylin 内核
bash diskwipe-iso/build.sh kylin    # 强制 Kylin 内核（需已解压 kylin-src/，见下）
bash diskwipe-iso/build.sh ubuntu   # 强制 WSL Ubuntu generic 内核
```

**Kylin 内核材料准备**（v1.4.1 起自动检测 `diskwipe-iso/kylin-src/boot/vmlinuz-4.19*` 存在即用 Kylin 内核构建）：

1. 把 `kylin-kernel-export.sh` 拷到目标 Kylin 服务器，执行 `bash kylin-kernel-export.sh`，得到 `kylin-src-<日期>.tar.gz`（含 `boot/vmlinuz-*`、`modules/<内核版本>/`、`firmware/`）；
2. 把 tar.gz 传回本机放入 `diskwipe-iso/`，解压出 `kylin-src/` 目录（`tar -xzf kylin-src-<日期>.tar.gz -C diskwipe-iso/`）；解压目录不入库（git 忽略），tar.gz 作为构建材料入库保留；
3. 直接 `bash diskwipe-iso/build.sh` 即自动用 Kylin 内核构建（内核取 `kylin-src/boot/vmlinuz-4.19*`，模块按白名单 + 依赖链从 `kylin-src/modules/<ver>/` 提取）。

**构建流程**（全部在 WSL 虚拟盘文件系统 + `output/` 内产出 iso **文件**，绝不写任何真实块设备）：

1. apt 安装构建依赖（`busybox-static xorriso mtools grub-pc-bin grub-efi-amd64-bin linux-image-generic zstd xz-utils parted`——parted 提供 `partprobe`，xz-utils 供 Kylin 模式 `.ko.xz` 解压；另补装 `genisoimage` 提供 isoinfo）；
2. 组装 initramfs rootfs：静态 busybox + 全部 applet；util-linux 动态 `wipefs`/`lsblk`/`blkid` + parted 的 `partprobe`（`wipefs -a` 后刷新内核分区视图用；`ldd` 收集 .so 依赖按原路径布局拷入，chroot 实测可运行；busybox-static 无 blkid applet，退出写 U 盘（可写分区过滤）与系统盘判定依赖它）；**内核双模式模块组装**——ubuntu 模式：磁盘驱动白名单模块目录 + **zstd 解压**（`.ko.zst` → `.ko`，busybox 无 zstd 解压能力）后 `depmod` 生成 `modules.dep`；kylin 模式：从 `kylin-src/modules/<ver>/` 按白名单 + `modules.dep` 依赖链提取（`.ko.xz` → `xz` 解压为 `.ko`），`modules.dep/modules.alias` 等清单拷入并 `sed 's/\.ko\.xz/.ko/'` 改后缀，固件仅拷 `amd-ucode`；`src/` 四个脚本（`init` 强制 `chmod +x`，内核要求 /init 可执行）；`VERSION` 拷入 rootfs 为 `/diskwipe.version`（菜单横幅与日志文件头的版本来源）；
3. cpio 打包 initrd.img（gzip）；
4. 写 `boot/grub/grub.cfg`（内核参数 `console=tty0 console=ttyS0,115200n8`），放置 vmlinuz/initrd.img 到 rootfs/boot/（kylin 模式 vmlinuz 取自 `kylin-src/boot/vmlinuz-<ver>`）；
5. `grub-mkrescue` 生成 **BIOS + UEFI 双引导** iso（兼容主流服务器；现场 Secure Boot 不开，无需签名）；
6. `isoinfo` 校验：iso 含 `boot/grub/grub.cfg`、`boot/vmlinuz`、`boot/initrd.img`（目录树 + 实际抽取双检）；grub.cfg 含双 console 参数；initrd 内 /init 具执行位；initrd 内 `/diskwipe.version` 内容等于 VERSION；src 四脚本 `dash -n` 语法 0 错误；**kylin 模式追加**：boot/vmlinuz `strings` 检出 `4.19.90` 版本串（Kylin 内核证据）、initrd 内关键模块（ahci/usb-storage/nvme）为未压缩 `.ko` 且无 `.ko.xz`/`.ko.zst` 残留。

**产物**：`diskwipe-iso/output/diskwipe-v1.4.1.iso`（当前版本 1.4.1；Kylin 内核模式约 40M，Ubuntu 模式约 77M）。构建成功打印 iso 路径与使用说明；任何一步失败打印 `✗ ...` 并以非 0 退出（不静默）。

## 4. 写入 U 盘

> **注意：写入会覆盖 U 盘全部内容，执行前确认目标设备号，切勿写错盘。**

**Linux / 已有 Linux 环境（dd）**：

```bash
# 以 U 盘设备号为 /dev/sdX 为例（用 lsblk 确认，勿用整机系统盘）
sudo dd if=diskwipe-v1.4.1.iso of=/dev/sdX bs=4M status=progress
sync
```

**Windows（Rufus）**：

1. 打开 Rufus，在「设备」选择目标 U 盘；
2. 「引导类型选择」选中 `diskwipe-v1.4.1.iso`；
3. 写入方式选择 **DD 镜像**（保证 BIOS+UEFI 双引导兼容性；若默认「ISO 镜像」方式写出的 U 盘在某台机器引导失败，改用 DD 模式重写）；
4. 点「开始」等待完成。

## 5. 真机冒烟清单（交付前按此验收）

| 步骤 | 操作 | 期望结果 |
|---|---|---|
| 1 | 按第 4 节把 iso 写入 U 盘 | 写入完成无报错 |
| 2 | 目标服务器从 U 盘启动（BIOS/UEFI 均可；Secure Boot 关闭） | 出现引导菜单（`DiskWipe v1.4.1`），3 秒自动进入 |
| 3 | 启动第一屏（init 提示） | 全英文可读（`Mounted /proc`、`Disk driver modules loaded`、`Device nodes scanned` 等），无乱码 |
| 4 | 菜单**列出全部硬盘**（编号/设备/容量/型号，类型标注 SYS=系统盘 / DATA=数据盘 / UNK=未知） | 先出现 `Scanning disks... (please wait)`，随后每块目标盘一行（秒级出现，不卡死）；启动 U 盘、光驱不出现 |
| 5 | 默认全选（直接回车）或输入编号排除不想要的盘，再回车 | 打印 `Will wipe the following N disks (irreversible!). Type YES to confirm:` 清单，与预期一致 |
| 6 | 输入大写 `YES` 确认 | 逐盘输出 `OK /dev/<dev> reset to uninitialized`；失败盘显式 `FAIL /dev/<dev>: <英文原因>` |
| 7 | 退出（输入 0）后断电/重启 | 提示 `Exited. You may power off or reboot after done.` |
| 8 | **验证**：DiskGenius 或 `lsblk` 查看目标盘 | 目标盘**无分区**（`lsblk` 无分区子项；`lsblk -f` 无 FSTYPE），即「未初始化」 |

验证命令示例：

```bash
lsblk            # 目标盘名下无分区行
lsblk -f         # 目标盘无文件系统列（FSTYPE 为空）
```

**控制台三态可用**：显示器直连、IPMI 虚拟 KVM、串口 SOL（内核已带 `console=tty0 console=ttyS0,115200n8`，菜单读写经 `/dev/console` 继承的标准输入输出）。

## 6. 清理日志（内存日志 + 退出尽力写 U 盘）

清理过程的关键输出**无条件写内存**（`/tmp/diskwipe-log`，initramfs rootfs 即 tmpfs = 内存，一次启动会话一份文件，多轮清理**追加**同一文件；不受 U 盘 I/O 阻塞影响——这是 v1.3.2 根治「init 挂 U 盘日志介质后卡死进不去菜单」的关键：**init/菜单阶段全程零 U 盘 I/O**）。

- **内存日志**：menu 启动即创建 `/tmp/diskwipe-log/diskwipe-<YYYYmmdd-HHMMSS>.log`（如 `diskwipe-20261122-131400.log`），全部关键行实时写入；`0` 退出前打印 `Log kept in memory: <路径>`。
- **退出尽力写 U 盘**：0 退出时自动把内存日志**尽力写 U 盘一次**——枚举 U 盘可写分区（文件系统 vfat/exfat/ntfs，推荐 **Ventoy 数据区**或分区 U 盘；自动跳过卷标 `VTOYEFI` 的 Ventoy 32MB 引导分区，按顺序优先数据分区）→ `timeout 3` 挂载 → `cp` 日志 → 卸载。成功打印 `Cleanup log saved to USB`（日志落盘位置：`/<U盘>/diskwipe-<时间戳>.log`）；失败/无 U 盘打印 `WARN: could not write log to USB (disk I/O blocked or no USB); log kept in memory: <路径>`（**可抄录日志后断电**，不阻断退出）。若退出时 U 盘 I/O 仍阻塞（内核 D 状态）导致挂起——此时清理已完成，属可接受（提示断电即可）。
- **日志内容（四类）**：
  | 类 | 内容 |
  |---|---|
  | 基础信息 | 工具版本（读 initramfs 内 `/diskwipe.version`，构建时由 `VERSION` 拷入）、会话开始/结束时间、日志介质状态（memory） |
  | 盘清单 | 清理目标盘：设备、容量、型号、类型（SYS 系统盘 / DATA 数据盘 / UNK 未知） |
  | 每盘结果 | 每盘 `OK /dev/<dev> reset to uninitialized` 或 `FAIL /dev/<dev>: <英文原因>`，含失败汇总 |
  | 排除/跳过记录 | 会话内的排除编号汇总（如 `Excluded: 1,2`）与 `Only boot media found` 等汇总提示（按代码实际落日志内容，不含逐设备名） |
- **无 U 盘/写失败**：不阻断清理（清理照常执行、结果仍显示屏幕），退出时打印 `WARN: could not write log to USB ...` + 内存日志路径（v1.3.2 起不再有 `No writable log media found` 分支——日志必写内存）。
- **驱动覆盖**：initramfs 驱动白名单含 USB3 控制器（`xhci_pci`）与 **usb-storage/uas**（U 盘块设备生成必需，退出写 U 盘时用）；qemu 冒烟已实测虚拟 U 盘（VTOYEFI+数据区）可识别、退出时日志真实落盘（`Cleanup log saved to USB` + USB 数据区存在 `diskwipe-*.log`），见验证记录。

## 7. 交互说明

启动后自动进入菜单（无盘可清时直接提示并退出，见下）：

```
==============================================
  DiskWipe Tool 1.4.1 - Reset disks to uninitialized
==============================================
  #     Device  Size  Model/Status  Type
  ---------------------------------------------------
  1    /dev/sda  894G   HGST 7K6000 (SATA)  SYS
  2    /dev/sdb  894G   Samsung PM983 (NVME)  DATA
  ---------------------------------------------------
  Default: all selected. Enter exclusions (e.g. 1,2; empty = all)
  0 = exit (power off or reboot after done)
>
```

交互规则（与脚本实际行为逐条对应）：

- **默认全选**：直接回车 = 全部选中；输入编号（逗号/空格分隔，可多选如 `1,2`）= **排除**对应盘，非法/越界编号忽略；排除列表为空即全选。
- **输入 `0` 退出**：打印 `Exited. You may power off or reboot after done.` 后退出。
- **二次确认**：打印 `Will wipe the following N disks (irreversible!). Type YES to confirm:` 清单后，**必须输入大写 `YES`** 才执行；非 YES（含小写 yes）提示 `Cancelled (nothing wiped).` 并回到菜单。
- **清除流程**：每盘先 `umount` 全部子树挂载点 → `wipefs -a` 整盘 → **立即 `partprobe`**（刷新内核分区视图；失败仅 `WARN: partprobe failed ...`，不影响该盘结论）→ `wipefs -n` 验证；逐盘打印 `OK /dev/<dev> reset to uninitialized` 或 `FAIL /dev/<dev>: <英文原因>`（原因：`umount failed` / `wipefs -a failed` / `wipefs -n failed` / `signatures remain` / `not whitelisted`）。单盘失败不影响其他盘，失败盘会汇总列出（`Failed disks: ...`）。
- **循环刷新**：清除结束后回到主菜单（盘列表刷新），可继续清理或输入 `0` 退出。
- **列盘（v1.3.1 批量探测 + 超时兜底 + 进度反馈）**：进入菜单后先打印 `Scanning disks... (please wait)`（批量探测耗时对用户可见，不再假死），随后列表**秒级**出现。列盘循环内**零外部命令**：枚举（1 次 lsblk）→ 批量类型探测（1 次 lsblk + 1 次 blkid）→ 批量字段格式化一次完成并预计算，循环内仅 shell 字符串切分查表，**无逐盘 lsblk/blkid/awk 调用**（修复「逐盘探测中某次 exec 挂起拖死整个菜单」的真机卡死）。全部只读探测统一包 `timeout 3` 兜底：单次探测挂起 3 秒即超时返回——批量探测超时则**全部盘**标 `UNK`（批量探测为整体一次调用，超时即整批结果失效；类型仅提示，不影响清除）；**枚举超时/失败**打印 `ERROR: disk scan timed out or failed` 并自动重试一次，仍失败提示可安全重启并退出，**绝不误判「仅启动介质」**。枚举结果落日志（`Disks found: N (dev list)`）——卡住时日志可直接定位是枚举/探测/显示哪一阶段。清除操作（umount/wipefs/partprobe）**不加超时**（破坏性操作不能半途中断）。批量类型探测的 `blkid` **只带非 USB 盘的分区作设备参数**（v1.3.3 起不读 U 盘——U 盘及其分区不在参数中，即使 U 盘 I/O 阻塞也不影响菜单立即出现）。
- **类型标注**：探测到 OS 迹象（EFI 系统分区 / MBR 活动分区 / ntfs 等）标 `SYS`，无迹象标 `DATA`，判定失败（探测不到/超时）标 `UNK`——**仅提示，不影响可勾选**（系统盘、业务盘都清）。qemu 冒烟实测：ntfs 分区 → SYS、空白盘 → DATA、有分区但无文件系统签名（blkid 无该分区条目）→ UNK；initramfs 内 lsblk 不输出 PARTTYPENAME/PARTFLAGS 列时，GPT ESP / MBR 活动标志按 `DATA` 显示（类型仅提示，清除语义不受影响，与 v1.2.0 逐盘探测行为一致）。
- **启动介质保护**：`TRAN=usb` 的 U 盘与 `sr*` 光驱硬排除；若只剩启动介质（无可清硬盘），提示 `Only boot media found (no wipable disks; boot USB/optical drive auto-excluded)` 并退出，不执行任何清除。
- **启动失败兜底**：init 任一步失败（挂载/模块加载/mdev）打印英文错误（`ERROR: ...`）并**停留在救援 shell**（`Stuck at rescue shell (run commands to diagnose; type exit to quit)`，可输入命令排查，`exit` 退出），不会静默继续。

## 8. 驱动兜底（特殊 SAS/RAID 卡不识别盘）

**现象**：目标服务器启动 iso 后菜单为空（提示仅发现启动介质），或 init 停留在救援 shell 报模块加载失败——说明该服务器磁盘控制器驱动不在白名单/Ubuntu generic 未覆盖（如特殊 SAS/RAID 卡）。

**白名单模块**（init 逐模块加载，依赖模块经 `modules.dep` 自动带入）：Ubuntu 模式 `ahci libahci libata nvme nvme-core mpt3sas megaraid_sas virtio_blk virtio_pci xhci_pci sd_mod scsi_mod usb_storage uas`；Kylin 模式按 `uname -r` 含 `ky10` 自动切换为 `ahci libahci libata nvme nvme-core mpt3sas megaraid_sas virtio_blk sd_mod usb-storage uas nls_iso8859-1 vfat fat`（Kylin 的 xhci_pci/usbcore/scsi_mod/virtio_pci 为内核内建无需加载）。已覆盖主流 AHCI/NVMe/LSI/板载 RAID/虚拟化/USB3 控制器与 USB 存储（退出写日志 U 盘）；**仍未覆盖时**（如该服务器另有特殊 SAS/RAID 卡）：

**v1.4.1 推荐做法（Kylin 内核模式，自动化）**：目标服务器本身能正常识别盘（Kylin 系统内），直接用 §3 的 Kylin 内核材料流程——`kylin-kernel-export.sh` 提取该服务器内核材料 → `kylin-src/` 解压 → `build.sh` 自动用 Kylin 内核构建；Kylin 模式的 init 白名单与模块提取清单如需补充驱动，把对应模块名加进 `build-lib.sh` 的 `DW_KYLIN_MODULES` 与 `src/init` 的 Kylin `DRIVE_MODULES` 即可（依赖链自动解析）。

**手动替换路径（旧做法，仅 ubuntu 模式）**：

1. 在 Kylin 服务器上收集替换材料：
   - 内核：`/boot/vmlinuz-*`（目标服务器可用的内核镜像）；
   - 模块：`/lib/modules/<内核版本>/` 整个目录（至少含 `kernel/drivers/{ata,nvme,scsi,virtio}` 与 `kernel/drivers/usb/host`）。
2. 把材料替换 `build-lib.sh` 的取材来源：内核从「WSL `/boot/vmlinuz-*-generic`」换成 Kylin vmlinuz；模块目录从「WSL `/lib/modules/<kver>`」换成 Kylin 拷出的模块目录（同名版本目录布局），随后照常 `depmod`。
3. 重跑 `bash diskwipe-iso/build.sh ubuntu` 生成新 iso，重新写入 U 盘，回到第 5 节冒烟验收。

> 说明：设计文档（§10/§13）预留的自动化接口 `EXTRA_MODULES_DIR` 已由 v1.4.1 的 Kylin 内核模式实现同源能力（kylin-src 作为替换内核/模块来源自动接入组装流程），手动替换路径保留供参考。

## 9. 测试

**运行全部测试**（本机 Git Bash；共 355 项用例，任一失败整体退出非 0）：

```bash
bash diskwipe-iso/tests/run-all.sh
```

- Windows 下若 PATH 里的 `bash` 是 WSL 占位，请用显式 Git Bash：
  ```bash
  "C:\Program Files\Git\bin\bash.exe" diskwipe-iso/tests/run-all.sh
  ```
- 六个测试组：`t1_wipe`（核心逻辑：枚举/类型标注/umount→wipefs→partprobe→验证/逐盘独立/整盘含空格挂载点，89 项）、`t2_menu`（交互：默认全选/排除/YES/0 退出/循环刷新/仅启动介质/TRAN 空型号显示，61 项）、`t3_init`（initramfs 启动编排：挂载→模块白名单→mdev→exec menu.sh，失败进救援 shell（英文提示）；v1.3.2 断言 init 零 U 盘挂载（cmds.txt 无 `mount /dev/`），45 项）、`t4_log`（清理日志 v1.3.2：无条件内存日志（文件头/盘清单/每盘结果/文件尾）/退出写 U 盘成功与挂载失败路径/跳过 VTOYEFI/dw_log 写内存/init 零 U 盘 I/O（`dw_mount_log_media` 已删除），46 项）、`t5_ascii`（真机修复验收：N1 屏幕输出纯 ASCII / N2 SYS-DATA-UNK 标注 / N3 OK-FAIL 结果行 / N4 partprobe 时机与 WARN / N5 PARTPROBE_BIN 接缝 / N6 白名单扩展，37 项）、`t6_scan`（列盘批量探测与超时：H1 列盘循环零外部命令（cmds.txt 无逐盘 lsblk/blkid）/ H2 批量探测一次 lsblk+blkid 输出每盘类型 / H3 探测超时→全部盘标 UNK 菜单不挂死 / H4 timeout 接缝形态（`timeout 3 <cmd>`）/ H5 查表口径与逐盘判定一致 / H6 `Scanning disks...` 提示与 `Disks found` 日志 / H9b 退出写 U 盘（dw_save_log_to_usb）包 timeout / **H10 U 盘存在时批量 blkid 排除 USB（v1.3.3：blkid 只带非 USB 盘作设备参数，不读 U 盘）**，77 项）。
- **测试安全**：全部用例在临时目录以**假件注入**运行（`LSBLK_BIN`/`BLKID_BIN`/`WIPEFS_BIN`/`UMOUNT_BIN`/`PARTPROBE_BIN`/`TIMEOUT_BIN` 接缝变量指向假命令），wipefs/partprobe 假件只把调用参数记入 `cmds.txt`、绝不执行真实命令，**绝不触碰本机真实块设备**。

**语法校验**（initramfs 运行时只有 busybox ash，脚本必须保持 POSIX/ash 兼容）：

```bash
"C:\Program Files\Git\bin\bash.exe" --posix -n diskwipe-iso/src/*.sh diskwipe-iso/src/init
```

## 10. 交付后重测指引（v1.4.1 Kylin 内核版真机验收）

用 v1.4.1 iso（`output/diskwipe-v1.4.1.iso`，Kylin 内核模式）执行真机复测：

1. 写入 U 盘后从目标服务器启动（IPMI 虚拟 KVM 查看）。
2. **重点：确认 Kylin 内核正常引导、菜单必现**——v1.4.1 用 Kylin 4.19 内核（该服务器本身运行 Kylin 系统正常，USB 栈兼容），启动第一屏内核版本应为 `Linux version 4.19.90-89.11.v2401.ky10...`；随后 `Mounted /proc`→`Device nodes scanned`→`Scanning disks... (please wait)` 与盘列表**秒级出现**（v1.3.3 起批量探测 `blkid` 不读 U 盘，v1.4.1 起内核层不再有 Ubuntu xhci/USB 不兼容问题）；启动第一屏与菜单全部英文可读（无方框乱码）。
3. **全选**（直接回车）→ 大写 `YES` 确认 → 逐盘核对 `OK /dev/<dev> reset to uninitialized` / `FAIL /dev/<dev>: <英文原因>`。
4. 退出（输入 0）：核对打印 `Log kept in memory: <路径>`，随后要么 `Cleanup log saved to USB`（插了可写 vfat/ntfs U 盘；Kylin 4.19 无 exfat/ntfs3 模块，exfat U 盘会降级为内存日志），要么 `WARN: could not write log to USB ...`（无 U 盘/写失败，可抄录日志后断电）。
5. 退出后重启，用 **FirPE** 复查系统盘与业务盘均为「未初始化」（无分区/无系统）。
6. 若仍卡住或盘未清，**记录盘列表与每盘结果，并抄录/拍照退出时打印的内存日志路径内容**（`/tmp/diskwipe-log/diskwipe-*.log`，含 `Disks found: N (dev list)` 盘清单与每盘结果，可直接定位是枚举/探测/显示哪一阶段）反馈实现方定位。
