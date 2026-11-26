# Task 5 brief — v1.5.5 init 进度诊断 + 超时兜底（定位真机 sdb 后卡点）

## 背景

真机（UEFI + Ventoy + KVM VGA + IPMI）v1.5.4 已确认：**显示正常**（AST2500 显卡驱动
加载、fbcon 切换 128x48、VGA 可见内核日志）、**磁盘枚举正常**（sda 447GiB 三分区 +
sdb U 盘两分区，20.7s Attached）——v1.5.4 修复生效。但**卡在 sdb 枚举后**：20.7s 之后
VGA 无任何新内容（init 的进度行 "Disk driver modules loaded"/"Device nodes scanned"
未出现）→ init 阶段某处停住。qemu 无法复现（真机特有：mpt3sas 控制器 + UAS 大 U 盘）。

**v1.5.5 目标**：给 init 每个步骤加**进度输出**（fbcon 激活后 VGA 可见）+ **timeout
兜底**（用户态挂起自动跳过）→ 真机再测一次：要么直接通过，要么进度行精确定位卡点模块。

## 任务（精确）

### 1. `diskwipe-iso/src/init` 改造（保持 POSIX/ash，LF 行尾）

a) **磁盘模块循环**（现约 69-71 行）改为带进度 + timeout（**失败不再 init_rescue**——
   v1.5.5 保证到菜单，驱动缺失由 menu 盘列表体现；原 rescue 语义仅保留给 mount 失败）：
   ```
   for im in $DRIVE_MODULES; do
       echo "loading module $im"
       timeout 5 modprobe "$im" 2>/dev/null || echo "WARN: module $im load failed/timed out"
   done
   echo "Disk driver modules loaded"
   ```
b) **显卡循环**（v1.5.4 新增）改为带进度 + timeout：
   ```
   # v1.5.5：加进度 echo + timeout 兜底（驱动探测挂起时 5s 后跳过）
   for gv in ast mgag200 smifb bochs-drm cirrus virtio-gpu; do
       echo "loading video module $gv"
       timeout 5 modprobe "$gv" 2>/dev/null
   done
   ```
c) **mdev -s**（约 75 行）改为 timeout + 进度（失败仅警告不 rescue）：
   ```
   echo "device scan (mdev -s)"
   timeout 5 mdev -s || echo "WARN: mdev scan failed/timed out"
   echo "Device nodes scanned"
   ```
d) **保留**：mount 的 init_rescue（原第 61-66 行）、sleep + 3 轮 mdev 重试（原 84-88 行，
   内部 mdev 可同样包 timeout 5）、exec menu.sh（91 行）。
   注释更新说明 v1.5.5 语义（进度诊断 + timeout 兜底；D 状态（不可中断 I/O）用户态
   timeout 无效，若仍卡靠进度行定位）。

### 2. `diskwipe-iso/VERSION`：`1.5.4` → `1.5.5`。

### 3. 重新构建（WSL Kylin 模式）：`output/diskwipe-v1.5.5.iso`。

## 禁止改动

- `src/menu.sh`、`src/lib.sh`、`src/wipe.sh`、build-lib.sh（本次不改）、isolinux、
  grub.cfg 直启、embedded-efi.cfg、BOOTX64.EFI、xorriso。

## 验证（必须全部通过）

- **qemu A**（UEFI -vga std，参考 tmp/dw-smoke-uefi-v154.sh 改 VERSION 1.5.5）：fb0 +
  Console switching + 全流程（DiskWipe Tool 1.5.5、三盘、OK x3、Exited、Cleanup log）。
- **qemu B**（-vga none，参考 tmp/novid-v154.sh）：serial 兜底 + 内核启动 + init 流程
  （进度行 "loading module" 应出现）。
- **qemu C**（BIOS isolinux，参考 tmp/dw-smoke-v154.sh）：21 项回归（VERSION 1.5.5）。
- **tests t1-t6 回归**（diskwipe-iso/tests/，INIT_PATH 假件）：适配新进度 echo /
  timeout 语义——若断言「模块失败→init_rescue」或「无 loading echo」则更新断言
  （新语义：失败 WARN 继续；loading 行必现）。全部 PASS。
- **验证脚本留档** tmp/dw-smoke-uefi-v155.sh / tmp/novid-v155.sh / tmp/dw-smoke-v155.sh。

## 提交

commit：`fix(diskwipe-iso): init 加模块加载进度输出与 timeout 兜底（定位/跳过 sdb 后卡点，失败不再 rescue）；v1.5.5 重打包`

## 报告

写 `task-5-report.md`：改动 diff、构建关键行、A/B/C+tests 断言输出、commit hash。
返回：状态、commit hash、一行测试摘要、concerns。