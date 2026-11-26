# Task 11 brief — v1.5.11 菜单输入改键盘（/dev/tty0）+ HID 驱动保障

## 背景（v1.5.10 真机突破 + 输入问题）

v1.5.10 真机：系统完整启动、菜单出现、重试后列出盘（`Disks found: 1` + 盘列表 +
`Default: all selected` + `> ` 提示）。**但用户无法输入**（KVM USB 键盘按键无效）。

**根因**：菜单（menu.sh）从 stdin（init exec 继承的 `/dev/console`）读输入。内核
`console=tty0 console=ttyS0,115200n8` → **`/dev/console` 的输入映射到最后一个 console
（ttyS0 串口）**，而非键盘（tty0）→ KVM USB 键盘（走 tty0/VT）按键无效。菜单输出已由
v1.5.8 kmsg 镜像保证 VGA 可见，**输入通道需改**。

**修复**：
1. **menu.sh stdin 重定向到 /dev/tty0**（键盘；tty0 不存在则 fallback 保持原 stdin）。
2. **init 确保 HID 键盘驱动加载**（usbhid 内建则跳过、模块则加载——`timeout 5
   modprobe usbhid 2>/dev/null`，放显卡循环后）。

## 任务（精确）

### 1. `diskwipe-iso/src/menu.sh`：`while :` 主循环前加 stdin 重定向（POSIX/ash）
```
# v1.5.11：菜单输入重定向到 /dev/tty0（键盘/VT）——/dev/console 输入默认映射到最后一个
# console（ttyS0 串口），真机 KVM USB 键盘无效；tty0 不存在（无 VT）时 fallback 保持 stdin。
if [ -e /dev/tty0 ]; then
    exec 0< /dev/tty0
fi
```

### 2. `diskwipe-iso/src/init`：显卡循环后加 HID 驱动保障
```
# v1.5.11：确保 USB 键盘/鼠标（HID）驱动加载（内建则 modprobe 跳过无碍；模块则加载）。
# 真机 KVM USB 键盘需 usbhid 才能输入。
dw_progress "loading HID drivers (usbhid)"
timeout 5 modprobe usbhid 2>/dev/null
```

### 3. `diskwipe-iso/VERSION`：`1.5.10` → `1.5.11`。

### 4. 重新构建（WSL Kylin 模式）：`output/diskwipe-v1.5.11.iso`。

## 验证（必须全部通过）

**qemu 键盘注入改造（关键）**：menu stdin 改 /dev/tty0 后，qemu 的 `-nographic` 串口喂
键（FIFO→stdin→serial）不再到达菜单（输入走 tty0 键盘）。**qemu 冒烟脚本改为 USB 键盘
注入**：
- qemu 参数：`-display none -serial file:<out> -device usb-kbd
  -monitor unix:/tmp/dwmon.sock,server,nowait`（serial 输出到文件；monitor 走 unix socket）。
- 喂键：脚本连接 `/tmp/dwmon.sock`，用 `sendkey` 注入（`sendkey ret` 回车全选、
  `sendkey y` `sendkey e` `sendkey s` `sendkey ret` 组成 YES+回车、`sendkey 0` `sendkey ret`
  退出）。参考 qemu monitor sendkey 语法（qemu `-monitor` unix socket + `sendkey <key>`）。
- A/B/C 三组均按此改造（A 有盘全流程、B 无盘重试/reboot、C BIOS isolinux——BIOS 同样
  需要键盘注入）。

**断言**：
- **A**（UEFI -vga std 有盘）：DiskWipe Tool 1.5.11、三盘、OK x3、Exited、日志降级。
- **B**（-vga none 无盘）：Only boot media found → 重试 3 轮 → rebooting in 10s。
- **C**（BIOS isolinux 有盘）：21 项回归（VERSION 1.5.11）。
- **tests t1-t6**（WSL 跑，勿用 Git Bash）：适配 stdin 重定向（t2_menu：假 /dev/tty0
  存在时 stdin 重定向、不存在 fallback）+ init usbhid 加载（t3）。全部 PASS。

## 禁止改动

- src/lib.sh、src/wipe.sh、build-lib.sh、isolinux、grub.cfg、embedded、BOOTX64.EFI、
  xorriso。

## 提交

commit：`fix(diskwipe-iso): 菜单输入改 /dev/tty0（/dev/console 输入映射到串口致 KVM 键盘无效）+ init 加载 HID；v1.5.11 重打包`

## 报告

写 `task-11-report.md`：改动 diff、构建关键行、A/B/C+tests 断言输出（含 qemu 键盘注入
方法）、commit hash。返回：状态、commit hash、一行测试摘要、concerns。