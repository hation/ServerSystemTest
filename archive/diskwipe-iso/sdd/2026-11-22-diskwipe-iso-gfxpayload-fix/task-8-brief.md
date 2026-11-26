# Task 8 brief — v1.5.8 去掉 uas + exec/menu 诊断 + 菜单输出 kmsg 双通道

## 背景（卡点分析）

真机 v1.5.7 日志：驱动/显卡/mdev/sleep 全部正常推进到 `device settle wait (sleep)`
（14.89s），**之后 `menu.sh started` 未出现** → exec menu.sh 前或启动时卡住。
initrd 四脚本检查正常（存在/755/LF/shebang OK），排除文件层面问题。

**新嫌疑**：
1. **UAS 驱动绑定 U 盘**：v1.5.7 日志 `uas` 注册（14.55s）→ UAS 异步尝试绑定
   ASolid USB 盘 → 若 UAS 协议响应异常 → 内核 D 状态卡死 → 后续用户态（sleep 结束
   后的 exec）无法进行。**去掉 uas**（usb-storage 已足够枚举 sdb）。
2. **exec/menu 启动卡**：需诊断行定位（exec 前后 + menu argv0）。

**修复**：去掉 uas + exec/menu 启动诊断 + 菜单界面输出 kmsg 双通道（若 console
不可见，kmsg 通道保证界面可读）。

## 任务（精确）

### 1. `diskwipe-iso/build-lib.sh`：`DW_KYLIN_MODULES` 白名单去掉 `uas`
（注释：v1.5.8 UAS 绑定 U 盘可能内核 D 状态卡死；usb-storage 已足够枚举 U 盘）。

### 2. `diskwipe-iso/src/init`：
a) Kylin 模式的 `DRIVE_MODULES`（case *ky10* 分支）去掉 `uas`（注释同上）。
b) exec 段（现第 105-106 行）改为带诊断 + 失败兜底：
```
# 5) 进入交互菜单（exec 替换自身；v1.5.8 加诊断：exec 前后进度，失败兜底救援 shell）
dw_progress "exec menu.sh"
exec "$(dirname "$0")/menu.sh" || {
    dw_progress "exec menu.sh FAILED"
    dw_progress "argv0=$0 dirname=$(dirname "$0")"
    exec sh
}
```

### 3. `diskwipe-iso/src/menu.sh`：
a) 头部（`. "$(dirname "$0")/lib.sh"` **之前**）加 argv0 诊断（不依赖 lib.sh）：
```
# v1.5.8：exec 后立即打点（不依赖 lib.sh 的 dw_progress，证明 menu 已被 exec 执行）
echo "diskwipe-init: menu.sh argv0=$0" > /dev/kmsg 2>/dev/null
```
b) **界面关键输出加 kmsg 镜像**（保险：若真机 /dev/console（tty0）输出不可见，kmsg
通道保证屏幕可读可操作）。涉及：横幅行、盘列表各行、`> ` 输入提示、`Type YES` 提示、
`OK ... reset` 行、`Exited.` 行。实现方式：这些行目前多为 `echo`/`dw_log` 输出——
**将 dw_log 已覆盖的行保持**（见 lib.sh 改造，dw_log 自动镜像 kmsg）；**直接 echo 的
界面行**（如 `> ` 提示）改为「echo 到 console + echo 到 kmsg」双写（保持交互逻辑不变，
仅加镜像输出）。**subagent 需逐处判断并最小改动**。

### 4. `diskwipe-iso/src/lib.sh`：`dw_log` 加 kmsg 镜像（menu 界面大量走 dw_log）：
```
dw_log() {
    echo "$msg" | tee -a "${LOG_FILE:-/dev/null}"
    echo "diskwipe-init: $msg" > /dev/kmsg 2>/dev/null
}
```
（保持 POSIX；`$msg` 原样语义不变）

### 5. `diskwipe-iso/VERSION`：`1.5.7` → `1.5.8`。

### 6. 重新构建（WSL Kylin 模式）：`output/diskwipe-v1.5.8.iso`。

## 禁止改动

- src/wipe.sh、isolinux、grub.cfg 直启、embedded-efi.cfg、BOOTX64.EFI、xorriso。
- menu.sh **只加诊断/镜像输出，严禁改交互逻辑**（输入读取、循环、选择/排除/YES 判断）。

## 验证（必须全部通过）

- **qemu A**（UEFI -vga std，参考 tmp/dw-smoke-uefi-v157.sh 改 VERSION 1.5.8）：全流程
  （DiskWipe Tool 1.5.8、三盘、OK x3、Exited、Cleanup log saved to USB）+ kmsg 诊断行
  （exec menu.sh / menu.sh argv0 / menu.sh started）。
- **qemu B**（-vga none，参考 tmp/novid-v157.sh）：serial 兜底 + 内核启动 + 诊断行。
- **qemu C**（BIOS isolinux，参考 tmp/dw-smoke-v157.sh）：21 项回归（VERSION 1.5.8）。
- **tests t1-t6 回归**：适配 uas 去掉（t3_init）、dw_log kmsg 镜像（t2_menu/t4_log）、
  exec 诊断行。全部 PASS。
- 验证脚本留档 tmp/dw-smoke-uefi-v158.sh / tmp/novid-v158.sh / tmp/dw-smoke-v158.sh。

## 提交

commit：`fix(diskwipe-iso): 去掉 uas（UAS 绑定 U 盘可能 D 状态卡死）+ exec/menu 启动 kmsg 诊断 + 菜单界面输出 kmsg 双通道；v1.5.8 重打包`

## 报告

写 `task-8-report.md`：改动 diff、构建关键行、A/B/C+tests 断言输出、commit hash。
返回：状态、commit hash、一行测试摘要、concerns。