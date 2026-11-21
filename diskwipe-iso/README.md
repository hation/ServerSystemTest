# diskwipe-iso：一键把硬盘恢复为「未初始化」的可启动 ISO 工具

- 版本：v1.1.0（`VERSION` 文件；iso 文件名含版本）
- 定位：替代「FirPE + DiskGenius 逐盘删分区」的现场流程——从 U 盘启动后自动进入干净终端菜单，列出全部硬盘（默认全选），大写 `YES` 二次确认后一键清除分区表与文件系统签名，硬盘**秒级**恢复为「未初始化」。无图形界面、无「保存更改」中间步骤、无界面干扰。

## 1. 工具用途与安全边界

**用途**：把压测服务器上全部（或部分）硬盘恢复为「未初始化」状态——清除分区表 + 盘内全部文件系统/RAID/LVM 签名，供下次重建分区或交接使用。

**清除强度（三条边界，务必知悉）**：

| 边界 | 说明 |
|---|---|
| 只清分区表 + 签名 | 对整盘执行 `wipefs -a`：清 GPT/MBR 分区表签名与盘内全部 fs/raid/PV 签名，再以 `wipefs -n` 验证（输出为空 = 已未初始化） |
| **不清数据块** | 不覆盖、不写零、不做安全擦除——数据块原文仍在盘上，只是分区表与签名被清；如需彻底抹除数据请另做安全擦除 |
| **不清 SMART** | `wipefs` 只写块设备的签名区，**不读写 SMART 属性**——盘的通电时间、通电次数等统计保持不变 |

**其他安全属性**：

- 运行时**完全离线**（不依赖网络；仅构建时需要网络）。
- 操作**不可恢复**：分区表与签名一经清除无法复原，执行前请确认目标盘。
- 启动介质保护：启动 U 盘（`TRAN=usb`）与光驱（`sr*`）**硬排除**，绝不误清；设备名有代码层白名单校验（仅 `sd[a-z]` / `nvme[0-9]n[0-9]` / `vd[a-z]` / `mmcblk[0-9]`，排除 `loop*` / `ram*`）。
- 不自动关机：清完后由现场手动断电/重启（屏幕提示）。

> **白名单限制**：`nvme[0-9]n[0-9]` 与 `mmcblk[0-9]` 仅匹配单个数字（即 nvme0n1~nvme9n1、mmcblk0~mmcblk9），`sd` 仅到 `sdz`（不含 sdaa 等）；超出范围的盘（如 nvme10n1、mmcblk10、sdaa）**不会列出，也绝不会被清除**——现场如遇此类盘请先调整盘位/名称使其落入白名单。
>
> **注意**：启动介质保护仅针对 `TRAN=usb` 的 U 盘与 `sr*` 光驱；**若直接从硬盘启动本 iso，该硬盘不会被排除，会正常出现在可清列表**（属设计口径，勿在装有系统/数据的硬盘上启动后回车清盘）。

## 2. 目录结构

```
diskwipe-iso/
├── README.md            本说明
├── VERSION              版本号（当前 1.1.0，iso 文件名含版本；构建时拷入 initramfs 的 /diskwipe.version）
├── .gitignore           忽略构建产物 output/（不入库）
├── build.sh             Windows 一键构建入口（经 WSL Ubuntu 执行）
├── build-lib.sh         构建函数库（apt 依赖→组装 initramfs→cpio→grub.cfg→grub-mkrescue→isoinfo 校验）
├── src/
│   ├── init             initramfs 启动脚本（挂载→白名单模块→mdev→exec menu.sh；失败进救援 shell）
│   ├── menu.sh          交互菜单（列盘/默认全选/排除/YES 确认/循环；0 退出）
│   ├── wipe.sh          清除入口（逐盘 umount→wipefs -a→wipefs -n 验证）
│   └── lib.sh           共享库（盘枚举/白名单/挂载点/类型标注/单盘清除）
├── output/              构建产物 diskwipe-v<版本>.iso（git 忽略，可随时由 build.sh 再生成）
└── tests/               离线测试（t1 核心逻辑 / t2 菜单 / t3 initramfs / t4 清理日志，共 226 项用例）
```

## 3. 构建（Windows 本机一键）

**前置条件**：

- WSL 已安装 **Ubuntu-24.04**（`build.sh` 会检测 `wsl -l -v` 是否含 Ubuntu；缺失时打印安装指引）；
- 需要**网络**（apt 下载构建依赖，首次耗时数分钟；重跑幂等，已装的包自动跳过）；
- WSL 内需 root 或免密 `sudo`（构建在 WSL 内 apt 安装依赖需要；指引见 build.sh 输出的安装步骤，含 `wsl --install -d Ubuntu-24.04` 与 `visudo` 追加 `NOPASSWD`）。

**命令**（在项目根目录执行）：

```bash
bash diskwipe-iso/build.sh
```

**构建流程**（全部在 WSL 虚拟盘文件系统 + `output/` 内产出 iso **文件**，绝不写任何真实块设备）：

1. apt 安装构建依赖（`busybox-static xorriso mtools grub-pc-bin grub-efi-amd64-bin linux-image-generic`，另补装 `genisoimage` 提供 isoinfo）；
2. 组装 initramfs rootfs：静态 busybox + 全部 applet；util-linux 动态 `wipefs`/`lsblk`（`ldd` 收集 .so 依赖按原路径布局拷入，chroot 实测可运行）；磁盘驱动白名单模块目录 + **zstd 解压**（`.ko.zst` → `.ko`，busybox 无 zstd 解压能力）后 `depmod` 生成 `modules.dep`；`src/` 四个脚本（`init` 强制 `chmod +x`，内核要求 /init 可执行）；`VERSION` 拷入 rootfs 为 `/diskwipe.version`（菜单横幅与日志文件头的版本来源）；
3. cpio 打包 initrd.img（gzip）；
4. 写 `boot/grub/grub.cfg`（内核参数 `console=tty0 console=ttyS0,115200n8`），放置 vmlinuz/initrd.img 到 rootfs/boot/；
5. `grub-mkrescue` 生成 **BIOS + UEFI 双引导** iso（兼容主流服务器；现场 Secure Boot 不开，无需签名）；
6. `isoinfo` 校验：iso 含 `boot/grub/grub.cfg`、`boot/vmlinuz`、`boot/initrd.img`（目录树 + 实际抽取双检）；grub.cfg 含双 console 参数；initrd 内 /init 具执行位；initrd 内 `/diskwipe.version` 内容等于 VERSION；src 四脚本 `dash -n` 语法 0 错误。

**产物**：`diskwipe-iso/output/diskwipe-v1.1.0.iso`（当前版本 1.1.0，约 71 MiB）。构建成功打印 iso 路径与使用说明；任何一步失败打印 `✗ ...` 并以非 0 退出（不静默）。

## 4. 写入 U 盘

> **注意：写入会覆盖 U 盘全部内容，执行前确认目标设备号，切勿写错盘。**

**Linux / 已有 Linux 环境（dd）**：

```bash
# 以 U 盘设备号为 /dev/sdX 为例（用 lsblk 确认，勿用整机系统盘）
sudo dd if=diskwipe-v1.1.0.iso of=/dev/sdX bs=4M status=progress
sync
```

**Windows（Rufus）**：

1. 打开 Rufus，在「设备」选择目标 U 盘；
2. 「引导类型选择」选中 `diskwipe-v1.1.0.iso`；
3. 写入方式选择 **DD 镜像**（保证 BIOS+UEFI 双引导兼容性；若默认「ISO 镜像」方式写出的 U 盘在某台机器引导失败，改用 DD 模式重写）；
4. 点「开始」等待完成。

## 5. 真机冒烟清单（交付前按此验收）

| 步骤 | 操作 | 期望结果 |
|---|---|---|
| 1 | 按第 4 节把 iso 写入 U 盘 | 写入完成无报错 |
| 2 | 目标服务器从 U 盘启动（BIOS/UEFI 均可；Secure Boot 关闭） | 出现引导菜单（`DiskWipe v1.1.0 硬盘清理工具`），3 秒自动进入 |
| 3 | 菜单**列出全部硬盘**（编号/设备/容量/型号，系统盘标注「系统盘」、其余「数据盘」） | 每块目标盘一行；启动 U 盘、光驱不出现 |
| 4 | 默认全选（直接回车）或输入编号排除不想要的盘，再回车 | 打印「将清除以下 N 块硬盘」清单，与预期一致 |
| 5 | 输入大写 `YES` 确认 | 逐盘输出 `✓ 已恢复未初始化：/dev/...`；失败盘显式标 `✗` |
| 6 | 退出（输入 0）后断电/重启 | 提示可断电/重启 |
| 7 | **验证**：DiskGenius 或 `lsblk` 查看目标盘 | 目标盘**无分区**（`lsblk` 无分区子项；`lsblk -f` 无 FSTYPE），即「未初始化」 |

验证命令示例：

```bash
lsblk            # 目标盘名下无分区行
lsblk -f         # 目标盘无文件系统列（FSTYPE 为空）
```

**控制台三态可用**：显示器直连、IPMI 虚拟 KVM、串口 SOL（内核已带 `console=tty0 console=ttyS0,115200n8`，菜单读写经 `/dev/console` 继承的标准输入输出）。

## 6. 清理日志（持久化落盘）

清理过程的关键输出会自动保存到 **U 盘可写分区**（一次启动会话一份文件，多轮清理**追加**同一文件；找不到可写介质时仅屏幕显示、不阻断清理）。

- **U 盘要求**：需有可写分区（文件系统 vfat/exfat/ntfs），推荐 **Ventoy 数据区**或分区 U 盘；启动时自动跳过卷标为 `VTOYEFI` 的 Ventoy 引导分区（32MB 启动区），按顺序优先挂载数据分区（只挂第一个可写分区）。
- **日志位置**：`/<U盘>/diskwipe-<YYYYmmdd-HHMMSS>.log`（如 `diskwipe-20261121-131400.log`）；`0` 退出前打印日志路径并尽力卸载 U 盘（卸载失败仅提示）。
- **日志内容（四类）**：
  | 类 | 内容 |
  |---|---|
  | 基础信息 | 工具版本（读 initramfs 内 `/diskwipe.version`，构建时由 `VERSION` 拷入）、会话开始/结束时间、日志介质状态（usb/none） |
  | 盘清单 | 清理目标盘：设备、容量、型号、类型（系统盘/数据盘/未知） |
  | 每盘结果 | 每盘 `✓ 已恢复未初始化` 或 `✗ <原因>`，含失败汇总 |
  | 排除/跳过记录 | 被排除的 U 盘/光驱设备名、白名单外设备跳过记录 |
- **无可写介质**：未插 U 盘/无可写分区时打印「未找到可写日志介质，本次日志仅屏幕显示。」，**不阻断清理**（清理照常执行、结果仍显示屏幕）。
- **当前限制（真实行为核对）**：initramfs 驱动白名单目前只加载 USB3 控制器（`xhci_pci`），**未加载 usb-storage/uas 驱动**——qemu 冒烟实测 U 盘在总线层可见但无块设备节点，日志走「仅屏幕」分支；即当前构建下 U 盘分区不可识别、日志尚不能落盘，后续版本将把 usb-storage/uas 纳入驱动白名单后自动落盘。

## 7. 交互说明

启动后自动进入菜单（无盘可清时直接提示并退出，见下）：

```
==============================================
  硬盘清理工具 1.1.0  清除分区并恢复为未初始化
==============================================
  编号  设备      容量    型号/状态              类型
  ---------------------------------------------------
  1    /dev/sda  894G   HGST 7K6000 (SATA)       系统盘
  2    /dev/sdb  894G   Samsung PM983 (NVMe)     数据盘
  ---------------------------------------------------
  默认已全部选中；输入要【排除】的编号（可多选如 1,2；直接回车=全部）
```

交互规则（与脚本实际行为逐条对应）：

- **默认全选**：直接回车 = 全部选中；输入编号（逗号/空格分隔，可多选如 `1,2`）= **排除**对应盘，非法/越界编号忽略；排除列表为空即全选。
- **输入 `0` 退出**：打印「已退出。清除完成后可断电或重启。」后退出。
- **二次确认**：打印将清除清单后，**必须输入大写 `YES`** 才执行；非 YES（含小写 yes）提示「已取消（未执行清除）」并回到菜单。
- **清除流程**：每盘先 `umount` 全部子树挂载点 → `wipefs -a` 整盘 → `wipefs -n` 验证；逐盘打印 `✓ 已恢复未初始化：/dev/...` 或 `✗ <失败原因>`。单盘失败不影响其他盘，失败盘会汇总列出。
- **循环刷新**：清除结束后回到主菜单（盘列表刷新），可继续清理或输入 `0` 退出。
- **类型标注**：探测到 OS 迹象（EFI 系统分区 / MBR 活动分区 / ntfs 等）标「系统盘」，无迹象标「数据盘」，判定失败标「未知」——**仅提示，不影响可勾选**（系统盘、业务盘都清）。
- **启动介质保护**：`TRAN=usb` 的 U 盘与 `sr*` 光驱硬排除；若只剩启动介质（无可清硬盘），提示「仅发现启动介质」并退出，不执行任何清除。
- **启动失败兜底**：init 任一步失败（挂载/模块加载/mdev）打印错误并**停留在救援 shell**（可输入命令排查，`exit` 退出），不会静默继续。

## 8. 驱动兜底（特殊 SAS/RAID 卡不识别盘）

**现象**：目标服务器启动 iso 后菜单为空（提示仅发现启动介质），或 init 停留在救援 shell 报模块加载失败——说明该服务器磁盘控制器驱动不在白名单/Ubuntu generic 未覆盖（如特殊 SAS/RAID 卡）。

**白名单模块**（init 逐模块加载，依赖模块经 `modules.dep` 自动带入）：`ahci libahci libata nvme nvme-core mpt3sas megaraid_sas virtio_blk virtio_pci xhci_pci sd_mod scsi_mod`。已覆盖主流 AHCI/NVMe/LSI/板载 RAID/虚拟化/USB3 控制器；**仍未覆盖时**按以下替换路径处理：

**手动替换路径（当前可用做法）**：

1. 在 Kylin 服务器上收集替换材料：
   - 内核：`/boot/vmlinuz-*`（目标服务器可用的内核镜像）；
   - 模块：`/lib/modules/<内核版本>/` 整个目录（至少含 `kernel/drivers/{ata,nvme,scsi,virtio}` 与 `kernel/drivers/usb/host`）。
2. 把材料替换 `build-lib.sh` 的取材来源：内核从「WSL `/boot/vmlinuz-*-generic`」换成 Kylin vmlinuz；模块目录从「WSL `/lib/modules/<kver>`」换成 Kylin 拷出的模块目录（同名版本目录布局），随后照常 `depmod`。
3. 重跑 `bash diskwipe-iso/build.sh` 生成新 iso，重新写入 U 盘，回到第 5 节冒烟验收。

> 说明：设计文档（§10/§13）为此预留了自动化接口 `EXTRA_MODULES_DIR`（把 Kylin 拷出的模块目录作为替换来源自动接入组装流程），**当前版本尚未接线**，按上述手动替换执行；后续版本再自动化。

## 9. 测试

**运行全部测试**（本机 Git Bash；共 226 项用例，任一失败整体退出非 0）：

```bash
bash diskwipe-iso/tests/run-all.sh
```

- Windows 下若 PATH 里的 `bash` 是 WSL 占位，请用显式 Git Bash：
  ```bash
  "C:\Program Files\Git\bin\bash.exe" diskwipe-iso/tests/run-all.sh
  ```
- 四个测试组：`t1_wipe`（核心逻辑：枚举/类型标注/umount→wipefs→验证/逐盘独立/整盘含空格挂载点，79 项）、`t2_menu`（交互：默认全选/排除/YES/0 退出/循环刷新/仅启动介质/TRAN 空型号显示，59 项）、`t3_init`（initramfs 启动编排：挂载→模块白名单→mdev→exec menu.sh，失败进救援 shell，38 项）、`t4_log`（清理日志持久化：介质挂载/跳过 VTOYEFI/会话级单文件多轮追加/无介质降级/0 退出卸载/版本回退/写失败不阻断，50 项）。
- **测试安全**：全部用例在临时目录以**假件注入**运行（`LSBLK_BIN`/`BLKID_BIN`/`WIPEFS_BIN`/`UMOUNT_BIN` 接缝变量指向假命令），wipefs 假件只把调用参数记入 `cmds.txt`、绝不执行真实 wipefs，**绝不触碰本机真实块设备**。

**语法校验**（initramfs 运行时只有 busybox ash，脚本必须保持 POSIX/ash 兼容）：

```bash
"C:\Program Files\Git\bin\bash.exe" --posix -n diskwipe-iso/src/*.sh diskwipe-iso/src/init
```
