# U 盘挂载操作说明（离线服务器）

适用：Kylin V10 SP3 等 Linux 服务器，**U 盘刚插入、尚未挂载**，需要用 U 盘里的离线包（如 `offline-stress-pkg`）。

本说明**不依赖 U 盘内任何脚本**，命令可直接复制执行。

---

## 1. 最快路径（三步搞定）

```bash
sudo mkdir -p /mnt/usb
sudo mount /dev/sdb1 /mnt/usb      # 把 sdb1 换成你的 U 盘分区（见第 2 节确认）
ls /mnt/usb
```

> 不知道设备名？先执行第 2 节；或直接用第 7 节的"一键自动识别"命令块。

---

## 2. 确认 U 盘设备名

```bash
lsblk -f
```

输出中重点看三列：`NAME`（设备名）、`FSTYPE`（文件系统）、`MOUNTPOINT`（挂载点）。
`FSTYPE` 有值（如 `vfat`/`ext4`/`ntfs`）、`MOUNTPOINT` 为空的那一行，就是**尚未挂载的 U 盘分区**。

也可以用带传输类型的方式确认哪块是 USB 盘：

```bash
lsblk -o NAME,SIZE,TYPE,TRAN,MOUNTPOINT,FSTYPE
```

`TRAN` 列为 `usb` 的即是 U 盘。示例：

```
NAME   SIZE TYPE TRAN MOUNTPOINT FSTYPE
sda    447G disk sata           　
├─sda1 600M part      /boot/efi vfat
sdb    7.5G disk usb            　
└─sdb1 7.5G part                  vfat    ← 这就是 U 盘分区，未挂载
```

判断规则：
- 有分区（如 `sdb1`）→ 挂载**分区**：`/dev/sdb1`
- 整盘直接是文件系统（无子项）→ 挂载**整盘**：`/dev/sdb`

---

## 3. 挂载

```bash
sudo mkdir -p /mnt/usb
sudo mount /dev/sdb1 /mnt/usb      # 换成第 2 节确认的设备

# 验证
df -h /mnt/usb
ls /mnt/usb
```

看到 U 盘内容即挂载成功。

### 文件系统类型处理

| FSTYPE | 处理 |
|---|---|
| `vfat` / `ext4` / `xfs` | 直接 `mount`，无需额外参数 |
| `ntfs` | 若报 `unknown filesystem type 'ntfs'`：优先换 FAT32/ext4 格式 U 盘；或 `sudo mount -t ntfs-3g /dev/sdb1 /mnt/usb`（需已装 ntfs-3g） |
| `exfat` | 需已装 exfatprogs/exfat-utils；否则建议换 FAT32/ext4 格式 U 盘 |

中文文件名乱码时（vfat）：`sudo mount -o iocharset=utf8 /dev/sdb1 /mnt/usb`。

---

## 4. 挂载后使用离线包

**方式 A（推荐）：先复制到本地，再执行**

```bash
cp -r /mnt/usb/offline-stress-pkg /root/
cd /root/offline-stress-pkg
sudo bash install.sh
```

**方式 B：直接从 U 盘执行**（仅限只读类脚本；**不要**在 U 盘上跑硬盘压测）

```bash
cd /mnt/usb/offline-stress-pkg
sudo bash verify.sh
```

> 压测结果默认写在 `/root/stress-test/`，与本说明无关，不会写 U 盘。

---

## 5. 卸载 U 盘

```bash
cd /                       # 必须先离开挂载点，否则会报 busy
sudo umount /mnt/usb
```

也可用包内脚本 `sudo bash usb-eject.sh`（自动识别 U 盘并卸载全部挂载点，`--poweroff` 可断电）。

确认已卸载：`lsblk -f` 中该分区的 `MOUNTPOINT` 变为空。

---

## 6. 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| `lsblk` 看不到 U 盘 | 未识别 | 重新插拔；`dmesg \| tail -20` 看是否有 usb 识别日志；换 USB 口；虚拟机需在宿主侧把 U 盘直通给虚机 |
| `lsblk` 有盘但 `MOUNTPOINT` 已有值（如 `/run/media/root/xxx`） | 桌面/系统已自动挂载 | 直接用该路径访问；或先 `sudo umount <该路径>` 再按第 3 节挂载到 `/mnt/usb` |
| `mount: unknown filesystem type 'ntfs'` | 缺 ntfs-3g | 见第 3 节；最稳是换 FAT32/ext4 格式 U 盘 |
| `mount: wrong fs type, bad option, bad superblock` | 选错设备（整盘当成分区，或反之） | 用 `lsblk -f` 看 `FSTYPE` 出现在哪个节点，挂载有文件系统的那一层 |
| `mount: /dev/sdb1 is already mounted or /mnt/usb busy` | 已挂载或挂载点被占用 | `findmnt /mnt/usb`、`lsof +f -- /mnt/usb` 查看占用；`cd` 出挂载点后重试 |
| `target is busy`（卸载时） | 有进程/当前目录在挂载点内 | `cd /` 后重试；`fuser -vm /mnt/usb` 找到占用进程 |
| U 盘只读 | 写保护开关或文件系统异常 | 检查 U 盘写保护开关；必要时 `sudo mount -o ro` 只读挂载取数据 |
| 中文文件名乱码 | vfat 编码参数 | `sudo mount -o iocharset=utf8 /dev/sdb1 /mnt/usb` |

---

## 7. 命令卡（直接复制执行）

### 一键自动识别并挂载

```bash
USB_DISK=$(lsblk -no NAME,TRAN | awk '$2=="usb"{print $1; exit}')
if [ -z "$USB_DISK" ]; then echo "未检测到 USB 盘，请确认已插入（lsblk -f）"; else
  USB_PART=$(lsblk -no NAME,PKNAME,TYPE | awk -v d="$USB_DISK" '$2==d && $3=="part"{print $1; exit}')
  [ -z "$USB_PART" ] && USB_PART="$USB_DISK"
  echo "U 盘：/dev/$USB_PART"
  sudo mkdir -p /mnt/usb && sudo mount "/dev/$USB_PART" /mnt/usb && df -h /mnt/usb && ls /mnt/usb
fi
```

### 卸载

```bash
cd / && sudo umount /mnt/usb
```
