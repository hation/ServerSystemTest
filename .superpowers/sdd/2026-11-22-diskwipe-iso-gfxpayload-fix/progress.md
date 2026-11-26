# SDD ledger — plan: docs/superpowers/plans/2026-11-22-diskwipe-iso-gfxpayload-fix.md

## Preflight scan

- Task 1 与 Task 2：无共享文件冲突（Task 2 为整支复查）。
- 扫描结论：clean。

## Rulings (preflight)

- Ruling: 直接在 main 分支实现（用户既定开发模式，v1.3.x~v1.5.0 均如此），不用 worktree；
  push 需用户另行确认。代价：若需回退则动 main 历史。

## Task 1（gfxpayload 修复）— 实际已完成但未 commit/未 review

- subagent（被中断前）已完成：build-lib.sh 删 `set gfxpayload=text`、VERSION 1.5.0→1.5.1、
  构建 diskwipe-v1.5.1.iso、qemu 仿真 Ventoy UEFI 验证（efifb+fbcon+全流程 PASS，
  tmp/dw-ventoy-uefi-v151.out）。改动在工作树（未 commit）。
- 后续：真机测 v1.5.1 仍报错黑屏 → 根因升级：真机 UEFI 盲模式卡死（内核未启动），
  非显示问题。Task 1 的 gfxpayload 修复是必要非充分（保留）。
- Ruling: Task 1 改动将与 Task 2（直启）合并为一次 commit，避免中间态。

## Task 2（UEFI 直启版 v1.5.2，grub.cfg 去菜单直启）

- 实施：grub.cfg 改直启（去 menuentry/timeout）；v1.5.2 构建。真机仍盲模式卡死
  → 直启非充分条件（卡死点不在菜单渲染）。
- 与 Task 3 合并 commit（7a2bbc2）。

## Task 3（v1.5.3 serial 终端兜底）

- 实施：grub.cfg + embedded-efi.cfg 加 serial 终端（insmod serial + serial --unit=0 +
  terminal_output/input serial console）；BOOTX64.EFI 模块加 serial terminal；v1.5.3 构建。
- 验证（qemu -vga none 实证）：blind mode 仍打印但**内核照常启动 + init 全流程**
  → 盲模式卡死消除。commit 7a2bbc2。
- 发现：A 组（-vga std）无 efifb（精简 GRUB 无 efi_gop → 无 framebuffer 传递）→ 显示
  未解 → 引出 Task 4。

## Task 4（v1.5.4 initrd 显卡 DRM 驱动）

- 实施：DW_KYLIN_MODULES 加显卡种子（ast mgag200 smifb bochs-drm cirrus virtio-gpu，
  依赖链自动解析）；init 加显卡 modprobe 循环（失败静默）；VERSION 1.5.4。
- 验证：A（-vga std：fb0 + Console switching + 全流程 16 项 PASS）、B（-vga none serial
  兜底内核启动）、C（BIOS 21 项）、tests t1-t6 77 项 ALL PASS。commit 0829353。
- Task 4 review：Approved（2 条 Minor 不阻塞）。
- Task 4: complete（commits 7a2bbc2..0829353, review clean）

## 结尾整支复查（final whole-branch review）

- final review：**Approve（可合入）**——整支改动（commits 7a2bbc2 + 0829353，3 文件
  +43/-22）正确无越界；无 Critical/Important；4 条 Minor 不阻塞（2 条 deferred +
  构建 echo 文案过时 + Ventoy serial 模块依赖提示）。
- Task 1-4: complete；整支复查 clean（deferred minors: 4）

## Task 5（v1.5.5 init 进度诊断 + timeout 兜底）

- 实施：init 磁盘/显卡循环加 `loading module` 进度 echo + `timeout 5`（失败 WARN 继续、
  不再 rescue）；mdev 加 timeout 5 + WARN；VERSION 1.5.5。tests/t3_init.sh 适配新语义
  （timeout 假件、WARN 继续断言）。commit d14b9b7。
- 验证：tests t1-t6 全 PASS、qemu A 22 项 / B 7 项 / C 22 项 PASS。
- Task 5 review：Approved（5 项 Minor 不阻塞）。
- Task 5: complete（commit d14b9b7, review clean）
- 交付：diskwipe-v1.5.5.iso 真机测试中（进度行定位卡点 / timeout 跳过）

## Task 6（v1.5.6 显卡循环只留 ast + 进度改 /dev/kmsg）

- 背景分析：真机屏幕定格 sdb（19.66s）→ 卡点在 sdb 前 → init 显卡循环（ast 后 5 个
  无硬件显卡驱动 modprobe D 状态挂起，timeout 无效）嫌疑最大。
- 实施：dw_progress 写 /dev/kmsg（屏幕可见）；显卡循环只留 ast；DW_KYLIN_MODULES
  显卡种子只留 ast；VERSION 1.5.6。commit 3f70526。
- 验证：qemu A/B/C + tests 全 PASS。Task 6 review：Approved（3 条 Minor 不阻塞）。
- Task 6: complete（commit 3f70526, review clean）
- 交付：diskwipe-v1.5.6.iso 真机测试中（若仍卡，kmsg 进度行留屏可见）

## Task 7（v1.5.7 去掉设备重试扫描 + menu/lib 全进度）

- 背景：v1.5.6 真机日志确认卡在 init 设备重试扫描（U 盘 sdb 枚举后重试 mdev 触发
  内核 D 状态 I/O 阻塞，timeout 无效）→ menu 不启动。
- 实施：init 重试段去 mdev 只 sleep 3；lib.sh 新增 dw_progress（/dev/kmsg）+ 
  dw_save_log_to_usb 开头 timeout 5 mdev -s（补建 U 盘节点）；menu.sh 加 5 行进度；
  VERSION 1.5.7。commit cebce11。
- 验证：qemu A/B/C + tests 全 PASS。Task 7 review：Approved（4 项 Minor 不阻塞）。
- Task 7: complete（commit cebce11, review clean）
- 交付：diskwipe-v1.5.7.iso 真机测试中（预期出菜单；若仍卡 menu 内进度行留屏）

## Task 8（v1.5.8 去掉 uas + exec/menu 诊断 + 菜单输出 kmsg 双通道）

- 背景：v1.5.7 真机卡在 settle wait 后（menu.sh started 未出现）→ exec/menu 启动前卡；
  嫌疑 UAS 绑定 U 盘 D 状态。
- 实施：去 uas（build-lib + init + tests 一致）；init exec 加诊断（exec menu.sh 打点 +
  失败兜底）；menu.sh argv0 打点 + 界面输出 kmsg 镜像（交互零改动）；lib.sh dw_log
  加 kmsg 镜像；VERSION 1.5.8。commit 7b66568。
- 验证：qemu A/B/C + tests 411 项全 PASS。Task 8 review：Approved（3 项 Minor 不阻塞）。
- Task 8: complete（commit 7b66568, review clean）
- 交付：diskwipe-v1.5.8.iso 真机测试中（exec/menu 诊断行定位；若出菜单即成功）

## Task 9（v1.5.9 去掉 usb-storage，根治设备枚举系统级停滞）

- 背景：v1.5.8 真机 settle wait 后系统整体停滞 >30s（sleep 3 都无法完成，exec 打点未
  出现）→ U 盘（ASolid）usb-storage 绑定读盘触发内核 I/O 阻塞（系统级，非 init）；
  用户确认无法换 U 盘。
- 实施：init Kylin DRIVE_MODULES 与 build-lib DW_KYLIN_MODULES 去掉 usb-storage
  （U 盘不绑定为存储设备 → 不读盘 → 系统正常启动；USB 键盘走内建 usbhid 不受影响；
  日志写 U 盘降级留内存）。VERSION 1.5.9。commit d7da880。
- 验证：qemu A/B/C + tests 413 项全 PASS（WSL 环境）。Task 9 review：Approved
  （1 条 Important：reviewer 在 MSYS Git Bash 重跑 t3 I6 2 项 FAIL——chmod -x 对
  Windows 文件无效的环境问题；WSL 复跑 t3 91 项 ALL PASS 确认代码正确）。
- Ruling: I6 Important 判定为 reviewer 环境差异（MSYS chmod 限制），非代码缺陷，
  park（WSL/Linux 生产环境 chmod 语义正常）。
- Task 9: complete（commit d7da880, review clean, 1 parked-environment）
- 交付：diskwipe-v1.5.9.iso 真机测试中（U 盘不绑定，预期系统正常启动出菜单）

## Task 10（v1.5.10 等设备就绪 + 无盘重试/reboot）

- 背景：v1.5.9 真机突破（系统不再卡死、menu 完整启动），但 sda（SAS）未就绪导致
  "Only boot media found" + menu 退出触发 PID1 panic（用户误判卡住）。
- 实施：init settle wait sleep 3→10；menu 无盘路径改重试（dwnoretry ≤3，sleep 5
  continue）+ 最终 reboot（10s 提示，不 exit 不 panic）；VERSION 1.5.10。
  commit f3e100e。
- 验证：qemu A/B/C + tests 418 项全 PASS。Task 10 review：Approved（3 项 Minor 不阻塞）。
- Task 10: complete（commit f3e100e, review clean）
- 交付：diskwipe-v1.5.10.iso 真机测试中（sda 就绪需数秒，耐心等菜单）

## Task 11（v1.5.11 菜单输入改 /dev/tty0 + HID）

- 真机：输入修复生效（用户能输入），但暴露：设备名提取失败（Disks found: 1 () +
  盘列表 /dev/ 空 + 回车全选 No disks selected）+ reboot 未生效（menu 循环）。
- 工作树改动未 commit，并入 Task 12。

## Task 12（v1.5.12 枚举诊断 + 勾选兜底 + reboot 强制）

- 实施：menu 枚举后加 RAW enum ml 诊断（kmsg 定位设备名空）；勾选 mdev 空时从 mtab
  sed 补；无盘后 reboot -f + sleep 2 fallthrough 保护（re-enumerating）；含 Task 11
  （stdin /dev/tty0、usbhid、settle wait 25、重试 6）；VERSION 1.5.12。commit 4c22a7f。
- 验证：qemu A/B/C + tests（t1:89/t2:86/t3:96/t4:50/t5:37/t6:77）全 PASS。
- Task 12 review：Approved（仅 Minor，无 Critical/Important）。
- Task 12: complete（commit 4c22a7f, review clean）
- 交付：diskwipe-v1.5.12.iso 真机测试中（RAW enum 诊断行定位设备名空）

## Task 13（v1.5.13 去掉无盘自动关机/重启——紧急安全修复）

- 背景：v1.5.12 真机 reboot -f 执行成关机，用户未及操作即断电（严重）。
- 实施：menu 无盘路径去掉 reboot/sleep 10/fallthrough → 无限重试（每 5 秒 continue，
  永不关机/重启）；init settle wait 25→10；VERSION 1.5.13。commit 8d6a538。
- 验证：qemu A/B/C + tests 全 PASS（B：无盘 150s 重试 170 轮零 reboot/关机字符串）。
- Task 13 review：Approved（无 Critical/Important）。
- Task 13: complete（commit 8d6a538, review clean）
- 交付：diskwipe-v1.5.13.iso 真机测试中（绝不自动关机，无盘持续重试等盘就绪）

## Task 14（v1.5.14 lsblk 原始诊断 + read -t 等待 + 降噪）

- 背景：v1.5.13 真机 sda 一直未枚举（RAW enum ml=[]）+ sleep 5 严重失真（0.17s，刷新疯）。
- 实施：menu 加 `RAW lsblk:` 原始输出诊断；sleep 5 改 `read -t 5 < /dev/tty0`（真实 5s
  等待）；重试消息每 10 轮一次；VERSION 1.5.14。commit 873f09c。
- 验证：qemu A/B/C + tests 77 项全 PASS（B：read -t 真实间隔 62s/10 轮，消息 4 条）。
- Task 14 review：Approved。Task 14: complete（commit 873f09c, review clean）
- 交付：diskwipe-v1.5.14.iso 真机测试中（关键看 RAW lsblk 诊断行定位 sda）

## Task 15（v1.5.15 强制 SCSI 重扫描——无效）

- 实施：init 加载后 + menu 枚举前 rescan（echo - - - > scsi_host/scan）；VERSION 1.5.15。
- 验证：qemu A/B/C + tests 全 PASS。review Approved。
- 真机：sda 仍未带出（lsblk 空）→ rescan 无效（无 scsi_host 可扫）。
- Task 15: complete（commit 9cd973b, review clean）

## 复盘 + 联网调研（用户要求想清楚再改，禁止乱改）

- 根因确认（Fedora/Broadcom 已知问题）：mpt3sas 默认 max_queue_depth=32455，海光高核数
  服务器 + initramfs 内存受限 → 内核无法分配大队列内存 → scsih_probe 失败 → 控制器未
  初始化（无 mpt3sas_cm0、无 scsi_host）→ 盘不识别（lsblk 空、rescan 无 host 无效）。
- v1.5.6 碰巧成功（时序/内存状态不同）；官方方案：max_queue_depth=10000。

## Task 16（v1.5.16 mpt3sas max_queue_depth=10000）

- 实施：init 白名单循环 mpt3sas 单独分支 modprobe mpt3sas max_queue_depth=10000
  （其余 $m 正常）；VERSION 1.5.16。commit ec74487。
- 验证：qemu A/B/C + tests 全 PASS（t3 99 项含分支断言）；review Approved。
- Task 16: complete（commit ec74487, review clean）
- 交付：diskwipe-v1.5.16.iso 真机测试中（max_queue_depth 无效，sda 仍未带出）

## Task 17（v1.5.17 恢复 usb-storage/uas——基于唯一成功证据）

- 复盘：v1.5.6（唯一 sda 识别成功）加载了 usb-storage/uas → mpt3sas_cm0 + sda 带出；
  v1.5.9 去掉后 sda 再未出现。修复 = 恢复 usb-storage/uas（触发 SCSI 扫描）+ 就绪后
  卸载（防 U 盘卡死）。
- 实施：init Kylin 白名单加回 usb-storage uas + settle 后 rmmod（busybox rmmod
  filename2modname 转换、多模块参数）+ 保持 max_queue_depth；build-lib 白名单加回 +
  6.6 断言翻转（构建必需修正）；VERSION 1.5.17。commit 468a737。
- 验证：qemu A/B/C + tests 全 PASS + isoinfo 实检 initrd 含 usb-storage.ko/uas.ko；
  review Approved（build-lib 断言翻转核实为必要）。
- Task 17: complete（commit 468a737, review clean）
- 交付：diskwipe-v1.5.17.iso 真机测试中（关键：sda 盘列表是否出现）
