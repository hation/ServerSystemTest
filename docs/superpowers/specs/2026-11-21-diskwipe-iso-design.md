# diskwipe-iso：一键恢复硬盘为未初始化的可启动 ISO 工具 设计

- 日期：2026-11-21
- 状态：待评审
- 依据：用户 2026-11-21 现场需求（替代 FirPE+DiskGenius 手动逐盘清分区流程）+ 本轮 brainstorming 逐项确认

## 1. 背景与问题

用户每次压测完成后需要把服务器全部硬盘恢复到"未初始化"状态（清系统盘系统、清业务盘压测数据、清分区表）。当前流程：FirPE 启动 → 打开 DiskGenius → 逐盘删除分区 → 逐个"保存更改"，痛点：

- 人为操作易遗漏/出错；删了分区忘记点"保存"直接退出 → 清空行为失效（白干）；
- DiskGenius 界面干扰多，易选错盘。

目标：一个可启动 ISO，开机自动进入干净菜单，列出所有硬盘（默认全选），二次确认后一键清除分区表+文件系统签名，硬盘即时恢复"未初始化"——**无"保存"中间步骤、无界面干扰**。

## 2. 已确认口径（用户决策，不得偏离）

| 项 | 口径 |
|---|---|
| 工具形态 | 独立 tools 文件夹 `diskwipe-iso/`，产出可启动 ISO（Linux 启动环境） |
| 清除强度 | **仅恢复到未初始化**：清分区表+文件系统签名（`wipefs -a` 整盘），秒级生效；不清数据块内容、不做安全擦除 |
| 交互 | 终端菜单（无图形依赖）：列盘 → **默认全选**，输入编号可排除、回车=全部 → 打印将清除清单 → **输入大写 `YES`** 二次确认 → 一键清除 |
| 盘类型标注 | 探测到 OS 分区标"系统盘"，其余标"数据盘"；**全部可勾选**（系统盘业务盘都清） |
| 启动介质保护 | 启动 U 盘（TRAN=usb）与光驱（sr*）**硬排除**，绝不误清 |
| 引导模式 | **BIOS + UEFI 双引导**（grub-mkrescue 生成；用户确认现场两种都可能出现） |
| Secure Boot | **现场不开，无需签名**（用户确认） |
| 控制台 | **三种都支持**：显示器直连、IPMI 虚拟 KVM、串口 SOL（内核加 `console=tty0 console=ttyS0,115200n8`） |
| 构建 | Windows 本机一键构建，经 **WSL（Ubuntu-24.04，已验证：DNS/网络/sudo 免密均可用）** 自动准备材料并出 iso；需网络 |
| 清后行为 | 显示每盘结果"已恢复未初始化 ✓"；不自动关机（用户手动断电/重启）；可继续操作或退出 |
| 交付 | 工具目录含 README、构建脚本、脚本源码；设计/计划文档入 `docs/superpowers/` |

## 3. 目标

- `build.sh`：Windows 本机一键（经 WSL）构建可启动 ISO。
- 启动环境：极简 Linux（内核 + 自定义 initramfs：busybox + 脚本 + util-linux 工具 + 磁盘驱动模块）。
- 交互脚本：`menu.sh`（列盘/勾选/确认）+ `wipe.sh`（umount→wipefs→验证）。
- 安全：U 盘/光驱硬排除；无 YES 不执行；清除失败显式列出。

## 4. 非目标

- 不做深度擦除/写零/安全擦除（不覆盖数据块）。
- 不重建分区、不格式化、不装系统。
- 不做图形界面（纯终端文本菜单，服务器现场接显示器/串口均可）。
- 不自动关机、不写日志到目标盘（日志输出到屏幕）。
- 不支持 Windows PE 变体（不基于 FirPE）。

## 5. 反目标（即使能跑也算失败）

- 误清启动 U 盘或光驱。
- 未二次确认（无 YES）就执行清除。
- 目标盘上有挂载点未卸载就 wipefs（必须先 umount 全部子树挂载点）。
- 清除后无验证（须用 `wipefs -n` 确认签名已清，仍残留 → 标失败）。
- 单盘失败吞掉不报（必须逐盘列出成功/失败）。
- 构建产物不可启动（iso 必须通过 isoinfo/实际引导校验）。
- 把工具做成依赖网络运行时才能用的东西（运行时完全离线，构建时才需网络）。
- **开发/测试过程中绝不触碰本机（Windows）真实物理块设备**（见 §5.1 测试安全声明）。

## 5.1 测试安全声明（用户强约束：测试不得触碰本机真实硬盘）

本工具开发/测试全流程在本机（Windows）进行，任何一步都不接触本机物理块设备（C 盘等），保障如下：

| 环节 | 运行环境 | 为什么碰不到真实盘 |
|---|---|---|
| 逻辑单元测试（M1-M10） | 本机 Git Bash + 临时目录（mktemp） | 全部走**假命令注入**：lsblk/blkid/wipefs 均为假件，wipefs 假件只把调用参数记入 cmds.txt、绝不执行真实 wipefs；脚本操作的"设备名"来自假件输出，不存在真实 /dev 设备 |
| 构建验证（build.sh） | WSL（Ubuntu-24.04，虚拟磁盘 ext4.vhdx） | apt 装包/组装 rootfs/cpio 打包/grub-mkrescue 只生成 iso **文件**，不写任何块设备；initramfs 脚本构建阶段仅做 `ash -n` 语法检查、不执行 |
| qemu 冒烟（可选） | WSL 内 qemu | 只带 `-cdrom diskwipe.iso -boot d` + 内存参数，**不映射任何宿主真实盘**（不传 -drive/-hda 指向真实设备） |
| 真机冒烟 | **目标服务器**（用户自己的压测机），U 盘启动 iso | 由用户在执行交付阶段自行操作，非本机、非开发阶段 |

另加一道代码层护栏：`wipe.sh` 对枚举到的设备名做白名单校验（仅允许 `sd[a-z]`/`nvme[0-9]n[0-9]`/`vd[a-z]`/`mmcblk[0-9]` 形态、且排除 `TRAN=usb` 与 `sr*`），测试假件同样受此约束，从源头杜绝误操作。

## 6. ISO 与启动环境设计

### 6.1 ISO 结构

```
diskwipe.iso (grub-mkrescue 生成：BIOS + UEFI 双引导)
├── boot/grub/grub.cfg                    # 引导菜单：linux /boot/vmlinuz + initrd /boot/initrd.img
│                                         #   （内核参数含 console=tty0 console=ttyS0,115200n8）
├── boot/vmlinuz                          # 内核（WSL 内 linux-image-generic 提供）
├── boot/initrd.img                       # 自定义 initramfs
└── (grub-mkrescue 自动生成 BIOS/UEFI 双引导镜像，无需手工 isolinux/EFI 镜像)
```

### 6.2 initramfs 内容（构建脚本组装）

```
initrd.img
├── init                     # 启动脚本：模块加载 → mdev 扫描 → exec menu.sh
├── menu.sh                  # 交互菜单（列盘/勾选/确认）
├── wipe.sh                  # 清除逻辑（umount→wipefs→验证）
├── lib/                     # 共享函数（盘枚举/标注/挂载点/确认）
├── bin/busybox              # 静态 busybox（含 lsblk/blkid/fdisk/mount/umount/modprobe/mdev 等 applet）
├── usr/sbin/wipefs          # util-linux 动态 wipefs（+ ldd 收集的 .so 依赖）
├── lib/modules/<ver>/       # 磁盘驱动白名单模块 + modules.dep（depmod 生成）
└── etc/                     # busybox 需要的最小配置
```

关键点（设计者已核实）：
- busybox **没有 wipefs applet**，必须带 util-linux 的 wipefs；动态二进制用 `ldd` 收集依赖（libblkid/libuuid/libc 等）一并拷入，init 里用动态 loader 运行。lsblk 优先用 util-linux 版（busybox lsblk 列选项受限），同样收集依赖。
- 内核磁盘驱动：Ubuntu generic 内核多数为模块（ahci/nvme/mpt3sas/megaraid_sas/virtio_blk 等）。init 里用 busybox `modprobe` 按 `modules.dep` 加载**白名单**模块；构建脚本用 `depmod -b rootfs` 生成依赖表。
- 模块白名单（覆盖主流服务器）：`ahci libahci libata nvme nvme-core mpt3sas megaraid_sas virtio_blk virtio_pci xhci_pci sd_mod scsi_mod` 及其依赖。

### 6.3 init 启动流程

```text
挂载 /proc /sys /dev → modprobe 白名单磁盘驱动 → mdev -s 扫描设备
→ 等待 2s 设备稳定 → exec /menu.sh
（任何一步失败打印错误并停留在 shell，不静默）
```

## 7. 交互设计（menu.sh）

```text
==============================================
  硬盘清理工具 v1.0  清除分区并恢复为未初始化
==============================================
  编号  设备      容量    型号/状态              类型
  ---------------------------------------------------
  1    /dev/sda  894G   HGST 7K6000 (SATA)       系统盘(检测到OS)
  2    /dev/sdb  894G   Samsung PM983 (NVMe)     数据盘
  ---------------------------------------------------
  默认已全部选中；输入要【排除】的编号（可多选如 1,2；直接回车=全部）：
  > _
```

- 确认界面（二次确认，输入 `YES` 才执行）：
  ```text
  将清除以下 2 块硬盘，清除后它们将恢复为【未初始化】：
    /dev/sda  894G  HGST 7K6000 (SATA)
    /dev/sdb  894G  Samsung PM983 (NVMe)
  此操作不可恢复！输入 YES 确认：> _
  ```
- 清除中逐盘显示进度；完成逐盘显示 `✓ 已恢复未初始化` 或 `✗ 失败原因`。
- 结束后回到主菜单（盘列表刷新），可继续或 0 退出（提示可断电/重启）。
- 无盘可清 → 提示后退出；启动 U 盘被识别为唯一非光驱盘时提示"仅发现启动介质"。

## 8. 盘识别与类型标注

- 枚举：`lsblk -o NAME,SIZE,TYPE,MODEL,TRAN,MOUNTPOINT` 中 `TYPE=disk` 的 `sd*/nvme*/vd*/mmcblk*`。
- 排除：`TRAN=usb`（启动 U 盘）；`sr*`/`loop*`/`ram*`（光驱/循环/内存盘）。
- 类型标注（仅提示，不影响可勾选）：
  - 系统盘：盘上有任一"OS 迹象"分区——EFI 系统分区（vfat 且分区标志 boot/esp）、Windows 系统分区（ntfs）、Linux 根分区（ext4/xfs/btrfs 且标志 boot 或含 `/etc/os-release` 痕迹）。用 `blkid` + 分区标志判定，判定失败标"未知"。
  - 数据盘：无上述迹象的盘。
- 型号/容量：lsblk MODEL/SIZE 列；SAS 卡盘型号可能为空，显示"未知型号"。

## 9. 清除逻辑（wipe.sh）

```text
对每个选中盘：
1) 收集该盘子树全部挂载点（lsblk MOUNTPOINT），逐个 umount
   - umount 失败 → 该盘失败（不 wipefs），记原因
2) wipefs -a /dev/<name>      # 清分区表签名 + 盘内全部 fs/raid/PV 签名
   - 失败 → 该盘失败，记原因
3) wipefs -n /dev/<name> 验证：输出为空 = 已未初始化 → ✓
   - 仍输出签名 → 该盘失败（残留），记原因
汇总：列出成功/失败盘清单
```

- 逐盘独立：单盘失败不影响其他盘。
- 不写任何日志文件到目标盘（屏幕输出即日志）。

## 10. 构建设计（build.sh，Windows 本机一键）

```text
1) 检测 WSL（wsl -l -v 含 Ubuntu）；缺失/不可用 → 打印安装指引并退出
2) wsl 内：apt-get update && apt-get install -y busybox-static xorriso grub-pc-bin grub-efi-amd64-bin linux-image-generic
3) 组装 initramfs（rootfs 目录）：
   - 拷贝静态 busybox
   - 拷贝 util-linux 的 wipefs/lsblk（ldd 收集 .so 依赖，动态 loader 运行）
   - 拷贝内核（/boot/vmlinuz-*）
   - 从 /lib/modules/<ver> 提取磁盘驱动白名单 + depmod 生成 modules.dep
   - 拷贝 init/menu.sh/wipe.sh/lib
4) cpio 打包 initrd.img
5) 写 grub.cfg（menuentry：linux /boot/vmlinuz console=tty0 console=ttyS0,115200n8；initrd /boot/initrd.img）
6) grub-mkrescue -o diskwipe-<版本>.iso -- -V DISKWIPE 打包 rootfs（自动生成 BIOS+UEFI 双引导）→ output/
7) 校验：isoinfo -i <iso> 列出 boot/grub/grub.cfg、boot/vmlinuz、boot/initrd.img 存在；打印 iso 路径与使用说明
```

- 构建脚本幂等（重复运行自动跳过已装包）。
- 版本号：`VERSION` 文件（v1.0.0 起），iso 名含版本。
- 驱动兜底：若构建产物在目标服务器不识别某些盘（特殊 SAS/RAID 卡），README 提供"从 Kylin 服务器拷 vmlinuz/模块"替换路径（构建脚本留接口：`EXTRA_MODULES_DIR`）。

## 11. 目录结构（diskwipe-iso/）

```
diskwipe-iso/
├── README.md            使用/构建说明 + 兜底路径
├── VERSION              v1.0.0
├── build.sh             Windows/WSL 一键构建
├── build-lib.sh         build 共用函数（WSL 检测/apt/组装/cpio/xorriso）
├── src/
│   ├── init             initramfs 启动脚本
│   ├── menu.sh          交互菜单
│   ├── wipe.sh          清除逻辑
│   └── lib.sh           盘枚举/标注/挂载点/确认 共享函数
├── output/              构建产物 diskwipe-<ver>.iso（git-ignored）
└── tests/               离线测试（假 lsblk/blkid/wipefs，沿用 sdd 风格）
```

## 12. 测试计划

### 12.1 逻辑单元测试（tests/，假命令注入，本机 Git Bash 可跑）

| 编号 | 场景 | 期望 |
|---|---|---|
| M1 | 枚举：sda(系统盘)/sdb(数据盘)/sdc(usb) + sr0 | 列表含 sda/sdb，排除 sdc、sr0；sda 标"系统盘"，sdb 标"数据盘" |
| M2 | 默认全选 | 回车=全部选中 |
| M3 | 排除编号 `1` | 只清 sdb |
| M4 | 输入非 YES | 不执行，返回菜单 |
| M5 | 输入 YES | 对选中盘依次 umount→wipefs -a→wipefs -n 验证 |
| M6 | 盘上有挂载点 | 先 umount 再 wipefs；umount 失败 → 该盘失败、其他盘继续 |
| M7 | wipefs -a 失败 | 该盘失败并记原因，不误报成功 |
| M8 | wipefs -n 仍有残留 | 该盘失败（残留） |
| M9 | 全部失败 | 汇总列出全部失败原因，退出非 0 |
| M10 | 无盘可清（仅 usb+光驱） | 提示"仅发现启动介质"，退出 |

### 12.2 构建验证（build.sh）

- 本机跑通 build.sh 生成 iso（输出目录）。
- `isoinfo` 验证 iso 含 `boot/grub/grub.cfg`、`boot/vmlinuz`、`boot/initrd.img`；grub.cfg 含 `console=tty0` 与 `console=ttyS0,115200n8`。
- initramfs 内脚本用 `ash -n` + `bash -n` 双重校验（initramfs 运行时只有 busybox ash，脚本必须保持 POSIX/ash 兼容）。
- 可选冒烟：qemu 启动 iso（若 WSL 有 qemu）确认出现菜单——不设硬性门槛（本机无 KVM 时跳过，README 注明真机验证步骤）。

### 12.3 真机冒烟（交付前用户执行，README 提供清单）

- U 盘写入 iso（dd/Rufus），目标服务器启动 → 菜单列出全部盘（含系统盘标注）→ 勾选/全选 → YES → 全部盘恢复未初始化（DiskGenius 或 `lsblk` 验证无分区）。

## 13. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 内核驱动不全（特殊 SAS/RAID 卡不识别盘） | Ubuntu generic 覆盖主流；白名单模块含 mpt3sas/megaraid_sas/virtio；README 提供 Kylin 内核/模块替换兜底（EXTRA_MODULES_DIR） |
| busybox 无 wipefs、动态 util-linux 依赖 glibc | ldd 收集 .so 依赖拷入 initramfs，动态 loader 运行；构建脚本自动处理 |
| 误清启动 U 盘 | TRAN=usb 硬排除；仅剩 usb 时明确提示不执行 |
| 误触 YES 清错盘 | 默认全选 + 排除交互 + 大写 YES + 将清除清单逐盘列出 |
| WSL 不可用/apt 失败 | build.sh 前置检测并给出安装指引；离线兜底（拷 Kylin 材料）在 README |
| iso 不可启动 | grub-mkrescue 双引导（BIOS+UEFI 兼容主流服务器，无需 Secure Boot 签名）+ isoinfo 校验 + README 真机验证清单 |
| 无头服务器串口黑屏 | 内核参数 console=tty0 console=ttyS0,115200n8；菜单走 /dev/console，SOL 可用 |
| 清后盘仍有残留 | wipefs -n 验证，残留标失败并提示重试/手动处理 |

## 14. 交付

- 工具目录 `diskwipe-iso/` 完整自包含（源码+构建脚本+README+VERSION）。
- 构建产物 iso 留在 `diskwipe-iso/output/`（不入 git）。
- 设计/计划文档入 `docs/superpowers/specs|plans/`。

## 15. 留给实现者的决定 / 设计者已定

- 设计者已定：默认全选交互；YES 二次确认；U 盘/光驱硬排除；wipefs 后 wipefs -n 验证；模块白名单；util-linux 动态二进制 + ldd 依赖收集；**GRUB2 双引导（grub-mkrescue，BIOS+UEFI）**；内核串口参数（console=tty0 console=ttyS0,115200n8，SOL/显示器/KVM 三态可用）；**脚本必须 POSIX/ash 兼容（initramfs 只有 busybox ash）**；版本 v1.0.0。
- 留给实现者：lsblk 具体列解析细节（MODEL 空值/多空格）；"OS 迹象"判定的具体 blkid+标志组合；menu.sh 的终端回显细节；build.sh 的 WSL 检测与 apt 幂等实现；grub.cfg 具体写法；测试假件组织（沿用 sdd 风格）。
