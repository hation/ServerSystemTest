# Task 29 brief — v1.5.29 实时写 U 盘诊断日志（摆脱 KVM 屏幕乱码，一次拿全证据）

## 背景（乱码是定位障碍，需干净日志）

30 轮真机调试最大障碍：**用户 KVM 屏幕日志乱码**（OCR 失真），DIAG 行（DIAG SAS/
DIAG mpt 等）看不清真实内容，导致无法确定根因（DIAG SAS 到底是否真空不可信）。
**解决方案**：工具实时把完整诊断写入 U 盘文件（用户测一次、拔 U 盘回电脑读干净日志）。
用户只需：测 v1.5.29 → 拔 U 盘 → 读 U 盘内日志文件（无乱码、完整）。

## 任务（精确，基于工作树——含 v1.5.20-28 未提交改动）

### 1. `diskwipe-iso/src/menu.sh`：每 N 轮枚举后把 DIAG 行 + dmesg 追加到 U 盘日志文件

在枚举诊断段（DIAG 行输出后）加「U 盘写日志」逻辑（复用 lib.sh 的
dw_save_log_to_usb 挂载思路，**写小文件 + timeout 兜底 + 失败降级不阻断**）：
```
# v1.5.29：实时把诊断写到 U 盘文件（摆脱 KVM 屏幕乱码——用户拔 U 盘回电脑读干净日志）。
# 每 5 轮写一次（防 U 盘 I/O 频繁）；挂载 sda1（vfat 数据区）追加 /diskwipe-diag.log；
# 全部包 timeout 3 兜底，失败降级（不阻断枚举/重试）。
if [ $((dwnoretry % 5)) -eq 1 ]; then
    (
        mkdir -p /mnt/dwdiag
        timeout 3 mount -t vfat /dev/sda1 /mnt/dwdiag 2>/dev/null &&
        {
            {
                echo "==== diskwipe-diag v1.5.29 $(date) retry=$dwnoretry ===="
                echo "RAW lsblk: $dwl"
                echo "DIAG hosts: $(ls /sys/class/scsi_host 2>/dev/null | tr '\n' '|')"
                echo "DIAG parts: $(cat /proc/partitions 2>/dev/null | tr '\n' '|')"
                echo "DIAG SAS: $(for d in /sys/bus/pci/devices/*; do v=$(cat "$d/vendor" 2>/dev/null); if [ "$v" = "0x1000" ]; then drv=$(readlink "$d/driver" 2>/dev/null || echo NONE); printf '%s:dev=%s:drv=%s|' "${d##*/}" "$(cat "$d/device" 2>/dev/null)" "$(basename "$drv")"; fi; done)"
                echo "DIAG pci: $(for d in /sys/bus/pci/devices/*; do drv=$(readlink "$d/driver" 2>/dev/null || echo NONE); printf '%s:%s|' "${d##*/}" "$(basename "$drv")"; done)"
                echo "DIAG mpt: $(dmesg 2>/dev/null | grep -iE 'mpt3sas|megaraid|megasas|scsih|probe|fail|chain_lookup|free_pages|max_queue_depth|fault' | tail -n 20 | tr '\n' '|')"
                echo "DIAG dmesg-tail: $(dmesg 2>/dev/null | tail -n 60 | tr '\n' '|')"
                echo "DIAG mods: $(for m in mpt3sas megaraid_sas usb_storage uas sd_mod scsi_mod libata ahci nvme virtio_blk; do [ -d "/sys/module/$m" ] && printf '%s|' "$m"; done)"
            } >> /mnt/dwdiag/diskwipe-diag.log 2>/dev/null
            sync
        }
        timeout 3 umount /mnt/dwdiag 2>/dev/null || true
    ) 2>/dev/null
fi
```
（**注意**：U 盘分区可能不是 sda1（vfat 数据区）；先探测 `/dev/sd*[0-9]` 含
vfat 分区挂载首个可写分区，兜底：`for p in /dev/sd[a-z][0-9] /dev/sd[a-z][a-z][0-9]; do
timeout 3 mount -t vfat "$p" /mnt/dwdiag && break; done`。Ventoy 数据区为 vfat。
失败全部静默降级——绝不阻断 menu。）

### 2. `diskwipe-iso/VERSION`：改为 `1.5.29`。

### 3. 重新构建（WSL Kylin 模式）：`output/diskwipe-v1.5.29.iso`。

## 禁止改动

- src/init、src/lib.sh、src/wipe.sh、build-lib.sh、isolinux、grub.cfg、embedded、
  BOOTX64.EFI、xorriso、白名单、内核参数（pci=realloc,nocrs 保留）、DIAG 行保留。

## 验证（必须全部通过）

- **qemu A**（UEFI -vga std 有盘 + U 盘）：全流程 + **断言 U 盘日志文件写入**（qemu
  U 盘挂载 sda1 后 diskwipe-diag.log 出现且含 DIAG 行——A 冒烟挂 U 盘盘）。
- **qemu B**（-vga none 无盘）：无限重试 + U 盘写日志每 5 轮；无 reboot/关机。
- **qemu C**（BIOS isolinux 有盘）：21 项回归（VERSION 1.5.29）。
- **tests t1-t6**（WSL 跑，勿用 Git Bash）：适配（U 盘写日志断言、%5 频率断言）。
  全 PASS。
- 验证脚本留档 tmp/dw-smoke-uefi-v1529.sh / tmp/novid-v1529.sh / tmp/dw-smoke-v1529.sh。
- **注**：真机验证由用户执行——测 v1.5.29 后拔 U 盘，回电脑读 U 盘内
  `diskwipe-diag.log`（干净完整日志：DIAG SAS/mpt/pci/hosts/parts/mods + dmesg 尾部）。

## 提交

commit：`feat(diskwipe-iso): 实时写 U 盘诊断日志（每 5 轮追加 diskwipe-diag.log——
摆脱 KVM 屏幕乱码，用户拔 U 盘读干净完整日志：DIAG SAS/mpt/pci/hosts/parts/mods +
dmesg，一次性确定根因）；v1.5.29 重打包`

## 报告

写 `task-29-report.md`：改动 diff、构建关键行、A/B/C+tests 断言输出（含 qemu U 盘
日志文件写入证据）、commit hash。返回：状态、commit hash、一行测试摘要、concerns。