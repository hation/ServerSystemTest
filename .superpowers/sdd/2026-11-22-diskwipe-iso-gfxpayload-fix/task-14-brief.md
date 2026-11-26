# Task 14 brief — v1.5.14 lsblk 原始输出诊断 + 减少重试刷新噪音

## 背景（真机 v1.5.13 定位）

v1.5.13 真机日志确认：
1. **`RAW enum ml=[]`**——盘（sda）一直未被 lsblk 枚举到（无限重试 500+ 轮仍空）。
   无法区分「sda 设备未就绪/不存在」vs「lsblk 有输出但 dw_enum_disks 的 awk 解析
   过滤掉了」→ **需加 lsblk 原始输出诊断**。
2. **sleep 5 严重失真**（真机实际 ~0.17s）→ 重试每秒几十轮、刷新疯狂（用户强烈不满）。
   注：qemu 亦失真（每轮 ~1s），真机更严重。**修复尝试：换 read -t 等待**（若 select
   时钟正常则有效）；同时**减少重试消息打印频率**（每 10 轮打一次）降低噪音。

## 任务（精确，基于 HEAD=8d6a538）

### 1. `diskwipe-iso/src/menu.sh`：加 lsblk 原始输出诊断
在现有 `dw_progress "RAW enum ml=[$ml]"` **之前**加（诊断 lsblk 原始输出——定位 sda
为何未被枚举）：
```
dw_progress "RAW lsblk: $(lsblk -o NAME,SIZE,TYPE,MODEL,TRAN,MOUNTPOINT 2>&1 | tr '\n' '|')"
```
（`tr '\n' '|'` 把多行压成一行进 kmsg；2>&1 捕获错误）

### 2. `diskwipe-iso/src/menu.sh`：重试等待换 `read -t`（尝试修复 sleep 失真）
无盘重试路径的 `sleep 5` 改为：
```
# v1.5.14：sleep 在真机严重失真（5s 实际 ~0.17s → 刷新疯狂）；read -t 用 select 超时，
# 若时钟正常则 5s 真实等待（等待期间用户按键可提前跳过——tty0 已重定向）。
read -t 5 dummy < /dev/tty0 2>/dev/null || true
```
（`read -t 5` 读 tty0 超时 5s；无输入则超时继续；`dummy` 变量名；POSIX 兼容）

### 3. `diskwipe-iso/src/menu.sh`：减少重试消息频率
重试消息仅每 10 轮打印（其余轮仅 kmsg 计数，不刷屏幕）：
```
dwnoretry=$((dwnoretry + 1))
if [ $((dwnoretry % 10)) -eq 1 ]; then
    dw_log "No wipable disks found yet (retry $dwnoretry). Retrying... (you may power off anytime)"
    dw_progress "no disks, retry $dwnoretry (never auto poweroff/reboot)"
fi
```
（每 10 轮打一次，屏幕噪音大减；枚举每轮仍进行）

### 4. `diskwipe-iso/VERSION`：`1.5.13` → `1.5.14`。

### 5. 重新构建（WSL Kylin 模式）：`output/diskwipe-v1.5.14.iso`。

## 禁止改动

- src/lib.sh、src/wipe.sh、build-lib.sh、isolinux、grub.cfg、embedded、BOOTX64.EFI、xorriso。

## 验证（必须全部通过）

- **qemu A**（UEFI -vga std 有盘）：全流程（DiskWipe Tool 1.5.14、三盘、OK x3、Exited、
  日志降级）+ `RAW lsblk:` 诊断行。
- **qemu B**（-vga none 无盘）：无限重试 + `RAW lsblk:` 诊断 + read -t 等待（断言
  read 调用/超时）+ 消息每 10 轮一次；无 reboot/关机。
- **qemu C**（BIOS isolinux 有盘）：21 项回归（VERSION 1.5.14）。
- **tests t1-t6**（WSL 跑，勿用 Git Bash）：适配（RAW lsblk 诊断、read -t 等待、
  消息频率）。全 PASS。
- 验证脚本留档 tmp/dw-smoke-uefi-v1514.sh / tmp/novid-v1514.sh / tmp/dw-smoke-v1514.sh。

## 提交

commit：`fix(diskwipe-iso): lsblk 原始输出诊断（定位真机 sda 未枚举）+ read -t 等待（sleep 真机失真）+ 重试消息降噪；v1.5.14 重打包`

## 报告

写 `task-14-report.md`：改动 diff、构建关键行、A/B/C+tests 断言输出、commit hash。
返回：状态、commit hash、一行测试摘要、concerns。