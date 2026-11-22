#!/bin/bash
# v1.3.2 qemu 冒烟（marker 驱动输入：全选->YES->0）
# 核心验证：v1.3.2 根治「init 阶段 U 盘日志介质 I/O 卡死进不去菜单」——
#   init 零 U 盘 I/O（不挂载/不探测日志介质）→ 菜单立即出现（横幅 1.3.2）；
#   日志全程写内存（header: log media: memory），0 退出时尽力写 U 盘成功
#   （虚拟 U 盘数据区可写 → "Cleanup log saved to USB"，日志真实落盘）。
# 盘布局（类型判定依赖 guest 真实工具链的可靠路径）：
#   vda 1G   MBR + 1 个 ntfs 分区           -> SYS（blkid TYPE=ntfs，真实压测机 Windows NTFS 系统盘场景）
#   vdb 256M 空白无分区表                    -> DATA
#   vdc 256M MBR + 1 分区（无 fs）           -> UNK（blkid 无该分区条目）
#   sda USB  (VTOYEFI 32M + DWLOGTEST 数据区 vfat) -> 启动介质保护排除 + 退出时日志写 U 盘目标
# 断言：横幅 DiskWipe Tool 1.3.2 / Scanning disks... / 列表三行 SYS-DATA-UNK /
#       OK vda/vdb/vdc / Exited / Log kept in memory / Cleanup log saved to USB /
#       USB 数据区存在 diskwipe-*.log（header log media: memory）/ 无 ERROR / 无 Only boot media
set -u
ISO=/mnt/c/Users/ganxin01/Documents/trae-work/ServerSystemTest/diskwipe-iso/output/diskwipe-v1.3.2.iso
OUT=/mnt/c/Users/ganxin01/Documents/trae-work/ServerSystemTest/tmp/dw-smoke-v132.out
KEY=/mnt/c/Users/ganxin01/Documents/trae-work/ServerSystemTest/tmp/dw-smoke-v132-keylines.txt
FIFO=/tmp/dwfeed-v132.fifo
cd /tmp || exit 1
rm -f dw-hdd-v132.img dw-usb-v132.img dw-vdb-v132.img dw-vdc-v132.img "$OUT" "$FIFO"

echo "=== [1] prepare virtual disks ==="
qemu-img create -f raw dw-hdd-v132.img 1G >/dev/null
printf 'label:dos\nstart=2048,type=83\n' | sfdisk dw-hdd-v132.img >/dev/null 2>&1
qemu-img create -f raw dw-vdb-v132.img 256M >/dev/null
qemu-img create -f raw dw-vdc-v132.img 256M >/dev/null
printf 'start=2048,type=83\n' | sfdisk dw-vdc-v132.img >/dev/null 2>&1
qemu-img create -f raw dw-usb-v132.img 64M >/dev/null
printf ',32M\n,,\n' | sfdisk dw-usb-v132.img >/dev/null 2>&1
LOOP=$(sudo losetup -fP --show dw-hdd-v132.img)
sudo mkntfs -Q -L DWSYS "${LOOP}p1" >/dev/null 2>&1
sudo losetup -d "$LOOP"
LOOP=$(sudo losetup -fP --show dw-usb-v132.img)
sudo mkfs.vfat -n VTOYEFI "${LOOP}p1" >/dev/null 2>&1
sudo mkfs.vfat -n DWLOGTEST "${LOOP}p2" >/dev/null 2>&1
sudo losetup -d "$LOOP"

echo "=== [2] boot qemu + marker feeder (enter -> YES -> 0) ==="
mkfifo "$FIFO"
timeout 150 qemu-system-x86_64 \
  -m 512M -cdrom "$ISO" -boot d \
  -drive file=/tmp/dw-hdd-v132.img,format=raw,if=virtio \
  -drive file=/tmp/dw-vdb-v132.img,format=raw,if=virtio \
  -drive file=/tmp/dw-vdc-v132.img,format=raw,if=virtio \
  -drive file=/tmp/dw-usb-v132.img,format=raw,if=none,id=usbstick \
  -device nec-usb-xhci,id=xhci -device usb-storage,drive=usbstick \
  -nographic -no-reboot < "$FIFO" > "$OUT" 2>&1 &
QPID=$!
exec 9>"$FIFO"
stage=0
for i in $(seq 1 300); do
    [ -d /proc/$QPID ] || break
    if grep -q "Default: all selected" "$OUT" 2>/dev/null && [ "$stage" -eq 0 ]; then
        printf '\n' >&9; echo "[feed] enter (all selected)"; stage=1
    elif grep -q "Type YES to confirm" "$OUT" 2>/dev/null && [ "$stage" -eq 1 ]; then
        printf 'YES\n' >&9; echo "[feed] YES"; stage=2
    elif grep -q "Default: all selected" "$OUT" 2>/dev/null && [ "$stage" -eq 2 ]; then
        printf '0\n' >&9; echo "[feed] 0 (exit)"; stage=3
    fi
    sleep 0.5
done
exec 9>&-
wait $QPID 2>/dev/null
echo "qemu exit=$?"

echo
echo "=== [3] key line assertions ==="
pass=1
chk() { if grep -q "$1" "$OUT"; then echo "PASS  $1"; else echo "FAIL  $1"; pass=0; fi; }
chk "DiskWipe Tool 1.3.2 - Reset disks to uninitialized"
chk "Scanning disks... (please wait)"
chk "Disks found: 3 (vda vdb vdc)"
chk '/dev/vda .*SYS'
chk '/dev/vdb .*DATA'
chk '/dev/vdc .*UNK'
chk "OK /dev/vda reset to uninitialized"
chk "OK /dev/vdb reset to uninitialized"
chk "OK /dev/vdc reset to uninitialized"
chk "Exited. You may power off or reboot after done."
chk "Log kept in memory:"
chk "Cleanup log saved to USB"
if grep -q "ERROR" "$OUT"; then echo "FAIL  (unexpected ERROR line)"; pass=0; else echo "PASS  no ERROR line"; fi
if grep -q "Only boot media found" "$OUT"; then echo "FAIL  (unexpected Only boot media)"; pass=0; else echo "PASS  no Only boot media"; fi
if grep -q "No writable log media" "$OUT"; then echo "FAIL  (unexpected No writable log media)"; pass=0; else echo "PASS  no No writable log media"; fi

echo
echo "=== [4] menu excerpt ==="
grep -nA10 "DiskWipe Tool 1.3.2" "$OUT" | head -n 40
echo
echo "=== [5] USB log evidence ==="
LOOP2=$(sudo losetup -fP --show dw-usb-v132.img)
sudo mkdir -p /mnt/dwlogx132
sudo mount "${LOOP2}p2" /mnt/dwlogx132 2>/dev/null
LOG=$(ls /mnt/dwlogx132/diskwipe-*.log 2>/dev/null | head -n 1)
if [ -n "$LOG" ]; then
  echo "log file: $LOG"
  sudo cat "$LOG" | tee "$KEY" >/dev/null
  echo "--- log content ---"
  sudo cat "$LOG"
  echo "--- log content END ---"
else
  echo "FAIL: no log on USB data partition"
  pass=0
fi
sudo umount /mnt/dwlogx132 2>/dev/null
sudo losetup -d "$LOOP2" 2>/dev/null

echo
echo "=== smoke verdict: $([ $pass -eq 1 ] && echo PASS || echo FAIL) ==="
[ $pass -eq 1 ] || exit 1
