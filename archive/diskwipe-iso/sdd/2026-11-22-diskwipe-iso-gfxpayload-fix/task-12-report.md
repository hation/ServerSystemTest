# Task 12 report — v1.5.12 枚举诊断（ml 原文）+ 勾选兜底 + reboot 强制

- 状态：**DONE**
- 分支：main（HEAD 前身 f3e100e = v1.5.10）
- commit：见文末（一次 commit 含 Task 11 + Task 12 全部工作树改动）

## 改动 diff（工作树 vs f3e100e，6 文件 +261/-41）

### `diskwipe-iso/src/menu.sh`（+56/-19 核心改动）
1. **枚举原文诊断**（`ml="$(dw_enum_disks)"` 后、列盘前）：
   ```sh
   # v1.5.12：枚举原文诊断（kmsg 输出枚举原文——真机屏幕可见，定位设备名空/格式异常的根因；
   # 例：无盘时显示 "RAW enum ml=[]" 即可确认枚举结果本身为空、而非设备名提取失败）
   dw_progress "RAW enum ml=[$ml]"
   ```
2. **勾选设备名兜底**（勾选循环 `mdev="${mline%% *}"` 后）：
   ```sh
   # v1.5.12 兜底：枚举行设备字段异常为空时（真机 Disks found: 1 () + /dev/ 空），
   # 从格式化行（mtab 第 mi 行，| 分隔首字段）补设备名——格式化经 awk 字段切分，
   # 对前导空白等异常更鲁棒；仍为空则该行放弃（不塞空设备名进选中清单）
   if [ -z "$mdev" ]; then
       mtabline="$(printf '%s\n' "$mtab" | sed -n "${mi}p")"
       mdev="${mtabline%%|*}"
   fi
   ```
3. **reboot 强制 + fallthrough 保护**（无盘重试 6 轮后）：
   ```sh
   dw_progress "no disks after retries, rebooting in 10s"
   sleep 10
   # v1.5.12：busybox reboot -f 强制重启（不依赖 init 守护——真机 reboot 未生效，
   # menu 继续跑）；若仍返回（未重启）→ fallthrough 保护：打印提示 + continue 重新
   # 枚举（此时若盘已就绪则正常列盘；避免反复 reboot 空转），绝不带着空 $ml 落入
   # 下方列盘段（否则空枚举行经格式化管道产生一条假盘行 "Disks found: 1 ()"）。
   reboot -f 2>/dev/null || true
   sleep 2
   dw_progress "reboot ineffective, re-enumerating"
   continue
   ```
4. 重试轮次 3 → 6（Task 11），注释更新为 v1.5.10/1.5.11/1.5.12 说明。

### `diskwipe-iso/src/init`（Task 11，+10/-5）
- 显卡循环（ast）后新增 HID 驱动保障：`timeout 5 modprobe usbhid 2>/dev/null`。
- settle wait `sleep 10` → `sleep 25`（真机 SAS 盘从驱动加载到 lsblk 可枚举约需 25 秒）。

### `diskwipe-iso/VERSION`（+1/-1）
- `1.5.10` → `1.5.12`（含 Task 11 的 1.5.11 未发布，直接到 1.5.12）。

### `diskwipe-iso/tests/t2_menu.sh`（+201/-47，测试适配）
- run_menu 全部经非特权 mount namespace（unshare -mU --map-root-user）执行：/dev 换 tmpfs 预置假设备，fallback（无 tty0）与 tty0（假 /dev/tty0=键盘输入流）两模式。
- M6 适配：重试 6 轮 + `reboot -f` 记录断言 + fallthrough（reboot -f 记录后 lsblk 返回就绪盘表 → continue 重新枚举 → 列盘 → 0 退出）。
- M10：RAW enum 枚举原文诊断行 kmsg 断言。
- M11（新）：/dev/tty0 stdin 重定向验证（输入来自假 tty0，stdin 接 /dev/null）。
- M12（新）：勾选设备名兜底（ml 前导空格异常行 + mtab 补设备名；对照无兜底复现 No disks selected）。

### `diskwipe-iso/tests/t3_init.sh`（+27/-10，测试适配）
- I1 断言 sleep 25（settle wait 加长）+ modprobe usbhid 调用 + kmsg HID 进度行 + usbhid 在 ast 之后、mdev -s 之前。
- I5（ky10）同样断言 modprobe usbhid。

### `diskwipe-iso/tests/t6_scan.sh`（+6/-1，测试适配）
- H7（枚举超时重试计数）加 `LOG_DIR="$ROOT/logdir"` 隔离：run-all 前序用例在同一秒窗口留下的 `/tmp/diskwipe-log/diskwipe-<秒>.log` 残留会让 `dw_save_log_to_usb` 误判日志存在而多执行一次 lsblk（实际 3 次，期望 2 次）——单独跑 t6 通过、run-all 必失败的偶发根因，LOG_DIR 指向用例临时目录根治。

## 禁止改动确认
- lib.sh / wipe.sh / build-lib.sh / isolinux / grub.cfg / embedded / BOOTX64.EFI / xorriso：零改动（git diff 确认）。

## 构建（WSL Kylin 模式）
- 脚本：`tmp/build-v1512.sh`（等价 build.sh kylin 模式，`DW_KERNEL_MODE=kylin` 加载 build-lib.sh 执行 dw_build_iso）。
- 产物：`diskwipe-iso/output/diskwipe-v1.5.12.iso`（40894464 B，39M）。
- 构建关键行（isoinfo 校验全过）：
  - xorriso 打包 BIOS(ISOLINUX)+UEFI(精简 GRUB) 双引导 iso → `/mnt/c/.../diskwipe-iso/output/diskwipe-v1.5.12.iso`；`ISO image produced: 19968 sectors`
  - `校验通过：isolinux.bin/ldlinux.c32/isolinux.cfg、EFI/BOOT/BOOTX64.EFI + efi.img、boot/grub/grub.cfg、boot/vmlinuz、boot/initrd.img 均在 iso 中`
  - `校验通过：isolinux.cfg 含 KERNEL /boot/vmlinuz + initrd=/boot/initrd.img + console=tty0/ttyS0,115200n8`
  - `校验通过：initrd 内 /diskwipe.version = 1.5.12`
  - `校验通过：initrd 内模块全部为未压缩 .ko（共 24 个，无 .ko.zst/.ko.xz 残留）`
  - `校验通过：initrd 内无 usb-storage.ko（v1.5.9 去掉，U 盘不绑定）`
  - `✓ 构建成功：...diskwipe-v1.5.12.iso（大小 39M）`

## 验证（全部 PASS）

### qemu A（UEFI -vga std 有盘全流程）— `tmp/dw-smoke-uefi-v1512.sh` → PASS
- 脚本改造说明：menu stdin 改 /dev/tty0 后串口喂键不再到达菜单，改 qemu monitor unix socket + `sendkey` USB 键盘注入（`-display none -serial file: + -device usb-kbd + -monitor unix:`）；冒烟实测首条 sendkey 可能被 HMP 初始化窗口吞掉，mon_send 连接后先消费初始 banner/(qemu) prompt 再发命令、发送后读响应查 error；注入前等 `"> "` 提示（菜单进入 read）再发。
- 关键断言 PASS：
  - `diskwipe-init: RAW enum ml=`（枚举原文诊断行，含 vda vdb vdc 设备名）
  - `DiskWipe Tool 1.5.12 - Reset disks to uninitialized`
  - `Disks found: 3 (vda vdb vdc)`；`/dev/vda .*SYS`、`/dev/vdb .*DATA`、`/dev/vdc .*UNK`
  - `OK /dev/vda|vdb|vdc reset to uninitialized`（x3）
  - `Exited. You may power off or reboot after done.` + `Log kept in memory:` + `WARN: could not write log to USB`（v1.5.9 降级）
  - `diskwipe-init: loading HID drivers (usbhid)`（v1.5.11 HID 保障）
  - 无 ERROR / 无 Only boot media / 无 Cleanup log saved to USB / 无非 ast 显卡模块

### qemu B（-vga none 无盘 → reboot -f fallthrough 保护）— `tmp/novid-v1512.sh` → PASS
- 关键断言 PASS：
  - `Only boot media found`（无盘重试消息，dw_log 双通道）
  - `no disks, retry 1/6..6/6`（重试 6 轮）
  - `diskwipe-init: RAW enum ml=`（无盘轮次枚举原文）
  - `no disks after retries, rebooting in 10s`（sleep 10 后 reboot -f）
  - `reboot -f 生效（qemu 于 reboot -f 后重启/退出；fallthrough 保护为防御路径——真机 reboot 无效时生效，单测 M6 覆盖）`
  - 无 usb-storage 加载 / HID 进度行 / exec menu.sh 诊断行全过

### qemu C（BIOS isolinux 有盘 21 项回归）— `tmp/dw-smoke-v1512.sh` → PASS（38 断言）
- 脚本改造说明（冒烟实测）：BIOS 模式挂 usb-kbd 触发内核 `usb usb1-port2: couldn't allocate usb_device`（qemu xhci BIOS 路径资源分配问题）→ USB 键盘未绑定、sendkey 不达菜单；改为 `-nographic -serial file:`（VGA 文本渲染与内核日志混入同一 serial 文件，ISOLINUX 横幅可断言）+ i8042 PS/2 键盘 sendkey 注入（BIOS 真实机器普遍有 PS/2 或 USB 键盘，注入方式仅验证引导链+菜单流程，PS/2 等价）。initrd 加载行因 VGA 渲染把 "Loading" 拆成 "L"+ANSI 序列+"oading"，断言后半段 `initrd.img...ok`。
- 关键断言 PASS：ISOLINUX 6.04 / Loading /boot/vmlinuz... ok / initrd.img...ok / Linux version 4.19.90 / RAMDISK: / DiskWipe Tool 1.5.12 / Disks found: 3 (vda vdb vdc) / SYS-DATA-UNK / OK x3 / Exited / Log kept in memory / WARN 降级 / no GNU GRUB / no ERROR / no Only boot media / RAW enum / HID 进度行。

### tests t1-t6（WSL 跑，勿用 Git Bash）— 全部 PASS
`tmp/runall-v1512c.log`：
- t1_wipe：通过 89 项，失败 0 项 → ALL PASS
- t2_menu：通过 86 项，失败 0 项 → ALL PASS
- t3_init：通过 96 项，失败 0 项 → ALL PASS
- t4_log：通过 50 项，失败 0 项 → ALL PASS
- t5_ascii：通过 37 项，失败 0 项 → ALL PASS
- t6_scan：通过 77 项，失败 0 项 → ALL PASS
- `==== 全部测试: ALL PASS ====`

## 验证脚本留档（tmp/）
- `tmp/dw-smoke-uefi-v1512.sh`（qemu A）
- `tmp/novid-v1512.sh`（qemu B）
- `tmp/dw-smoke-v1512.sh`（qemu C）
- 运行日志：`tmp/run-a-v1512.log`、`tmp/run-b-v1512.log`、`tmp/run-c-v1512.log`、`tmp/runall-v1512c.log`
- 诊断脚本（根因定位，留档）：`tmp/diag-a-v1512.sh`、`tmp/diag-c-v1512.sh`、`tmp/diag-c2-v1512.sh`、`tmp/repro-h7*.sh`

## 排查记录（concerns 依据）
1. **A 首轮 FAIL → sendkey 时序**：A 初版脚本 `[inject] ret` 后菜单无响应（qemu 8.2 HMP 首条命令可能被初始化窗口吞掉）。修复：mon_send 连接后 drain 初始输出再发命令 + 注入前等 `"> "` 提示出现（菜单已进入 read 阻塞）。修复后 A 连续 PASS。
2. **C FAIL 两因**：
   - `-display none -serial file:` 拿不到 ISOLINUX 横幅（VGA 文本渲染不输出到 serial）→ 改 `-nographic -serial file:`（v1510 同款方式）。
   - BIOS 模式挂 usb-kbd 触发 `couldn't allocate usb_device`（qemu xhci BIOS 路径资源分配问题）→ 去 usb-kbd，i8042 PS/2 键盘 + sendkey 注入。
3. **t6 H7 run-all 偶发失败**：单独跑 t6 通过、run-all 必失败（实际 3 次 lsblk vs 期望 2 次）。根因：t6 H7 用例未设 LOG_DIR，menu.sh 默认写 `/tmp/diskwipe-log/diskwipe-<秒>.log`；run-all 前序用例（t1-t5 的 menu 调用）在同一秒窗口留下同名残留文件 → `dw_save_log_to_usb` 的 `[ -f "$LOG_FILE" ]` 误判日志存在 → 多执行一次 `timeout 3 lsblk`（U 盘候选枚举）。修复：H7 加 `LOG_DIR="$ROOT/logdir"` 隔离（t6_scan.sh +6/-1）。修复后 run-all 连续 PASS。

## commit
- 一次 commit（含 Task 11 + Task 12 全部工作树改动）：
  `fix(diskwipe-iso): 枚举原文诊断 + 勾选设备名兜底（真机设备字段空致 No disks selected）+ reboot -f 强制与 fallthrough 保护；v1.5.12 重打包`
- hash：见提交输出。
