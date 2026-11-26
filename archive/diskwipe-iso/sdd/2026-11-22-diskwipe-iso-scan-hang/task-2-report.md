# Task 2 报告：构建（v1.3.0 重打包 + qemu 冒烟）+ README

- 日期：2026-11-22
- Commit：`4f56c3c release(diskwipe-iso): v1.3.0 列盘卡住修复（零 exec + 超时兜底）重打包`
- 状态：DONE_WITH_CONCERNS（1 项行为观察，详见 §6）

## 1. 版本升级

- `diskwipe-iso/VERSION`：1.2.0 → **1.3.0**。字节布局保持：纯 ASCII `1.3.0\n`（31 2E 33 2E 30 0A，6 字节，LF 行尾、无 BOM、无 CR——原文件本就无 BOM，布局不变）。

## 2. 重构建 + 校验

- `"C:\Program Files\Git\bin\bash.exe" diskwipe-iso/build.sh`（Git Bash）→ **`diskwipe-iso/output/diskwipe-v1.3.0.iso`，80,498,688 字节（77M）**，最终运行 EXIT=0。
- build-lib 内置校验全部通过：isoinfo 三关键文件（目录树 + 抽取实检）、grub.cfg 双 console、initrd /init 执行位、initrd `/diskwipe.version`=1.3.0、src 四脚本 dash -n 0 错误、模块全为 .ko 无 .ko.zst 残留。
- 独立复核（WSL，tmp/verify-v130.sh）：isoinfo -l 列出三文件（grub.cfg=148B / vmlinuz=15,128,968B / initrd.img=12,377,010B）；initrd 内 `/diskwipe.version` = `1.3.0` PASS；WSL dash -n 对 lib.sh/menu.sh/wipe.sh/init 全部 rc=0。
- 备注：首次调用 exit 1 为 WSL 冷启动瞬态（Ubuntu 由 Stopped 态自动拉起），重跑 EXIT=0 且全部校验通过、iso 独立复核无误。

## 3. qemu 冒烟（必做项）——PASS

- 盘布局（1G virtio + 虚拟 U 盘，另加两块小 virtio 以覆盖三类型标注）：
  - vda 1G：MBR + 1 个 **ntfs** 分区 → **SYS**（ntfs 经 blkid TYPE 判定，是 initramfs 内唯一可靠命中 SYS 的路径，亦为真实压测机 Windows NTFS 系统盘场景）
  - vdb 256M：空白 → **DATA**
  - vdc 256M：MBR + 1 分区（无文件系统）→ **UNK**
  - sda USB（VTOYEFI 32M + DWLOGTEST 数据区 vfat）→ 启动介质保护排除 + 日志介质
- marker feeder：回车(全选) → YES → 0(退出)，全程无挂起（150s 超时内完成，qemu exit=124 系外层 timeout 在「Exited」后收尾，正常）。
- **关键行断言（13/13 PASS）**：
  - 横幅：`DiskWipe Tool 1.3.0 - Reset disks to uninitialized`
  - `Scanning disks... (please wait)`；`Disks found: 3 (vda vdb vdc)`
  - 列表三行：`1 /dev/vda ... SYS`、`2 /dev/vdb ... DATA`、`3 /dev/vdc ... UNK`（列表完整显示、无挂起；busybox timeout/awk 工作正常）
  - 清除：`OK /dev/vda reset to uninitialized`（vdb/vdc 同）
  - `Exited. You may power off or reboot after done.`；`Cleanup log saved:`（USB 日志真实落盘：版本 1.3.0、`Disks found: 3 (vda vdb vdc)`、盘清单、逐盘 OK、session end 均在 `diskwipe-20261122-052716.log` 实证）
  - 无 `ERROR` 行、无 `Only boot media found`
- 冒烟脚本：`tmp/dw-smoke-v130.sh`；输出/关键行证据：`tmp/dw-smoke-v130.out`、`tmp/dw-smoke-v130-keylines.txt`。

## 4. README 更新（diskwipe-iso/README.md）

- 版本号全文同步 v1.3.0（标题、VERSION 说明、产物、dd/Rufus 示例、冒烟清单步骤 2、示例横幅、§10 标题与正文）。
- §1 新增 **v1.3.0 列盘卡住修复** 说明（零 exec 批量探测/预计算、timeout 3 只读探测兜底、枚举超时降级重试不误判仅启动介质、Scanning 进度提示、Disks found 日志、清除操作不加超时）。
- §5 冒烟清单步骤 4：先出现 `Scanning disks... (please wait)` 再秒级出列表（不卡死）。
- §7 交互规则：新增「列盘（v1.3.0 批量探测 + 超时兜底 + 进度反馈）」条目（与脚本实际行为逐条对应，交叉核对真实行为）；「类型标注」补充 qemu 冒烟实测口径（ntfs→SYS、空白→DATA、无 fs 分区→UNK；initramfs 内 lsblk 不输出 PARTTYPENAME/PARTFLAGS 时 GPT ESP/MBR 活动标志按 DATA）。
- §9：281 → **347 项用例**；五个测试组 → 六个（新增 `t6_scan` 66 项描述）；测试安全接缝清单补 `TIMEOUT_BIN`。
- §10 交付后重测指引保持结构并升级 v1.3.0：观察 `Scanning disks...` 后列表出现 → 全选 → YES → 逐盘 OK/FAIL → 重启后 FirPE 复查；仍卡则上传增强日志（含 `Disks found` 盘清单与每盘结果）定位。

## 5. 回归 + Commit

- `bash diskwipe-iso/tests/run-all.sh`（Git Bash）→ **347 PASS / 0 FAIL**（t1-t6：89/61/44/50/37/66，`==== 全部测试: ALL PASS ====`）。
- `bash --posix -n diskwipe-iso/src/lib.sh diskwipe-iso/src/menu.sh diskwipe-iso/src/wipe.sh diskwipe-iso/src/init` → 0 错误。
- Commit：`4f56c3c`，仅 `diskwipe-iso/VERSION` + `diskwipe-iso/README.md` 两文件（+21/-18）；output/ 忽略不入库；其余工作区改动（docs/压测报告等）未触碰。

## 6. 自审结论与 Concerns

- 自审：全部门禁按序通过（版本字节 → 构建 → isoinfo/initrd/dash -n → qemu 冒烟 → README 交叉核对 → 回归 → 提交）；只动了 VERSION / README（+ 忽略的 output 产物与 tmp 诊断脚本，均未入库）。
- **Concern 1（行为观察，非回归）**：qemu 冒烟与 initramfs chroot 双重实证——**guest 内 lsblk 的 PARTTYPENAME/PARTFLAGS 列恒为空**（内核 sysfs 不提供 GPT 类型/引导标志，initramfs 内 lsblk 也不回退读盘探测），因此 GPT ESP / MBR 活动分区在真机 iso 环境中按 **DATA** 显示，SYS 仅由 **ntfs**（blkid TYPE）可靠触发。v1.2.0 逐盘探测同样依赖该 lsblk 数据源，行为一致，**非本次变更引入的回归**；类型仅提示、不影响清除语义。已如实写入 README §7。若需 GPT ESP 判 SYS，需改用 blkid 的 PARTUUID/PTTYPE 或读盘探测（超出本任务范围，建议后续版本评估）。
- Concern 2：冒烟第一轮曾发现裸 `grep SYS` 断言假阳性（命中内核日志 `LNXSYSTM`/`SYSCALL`），已改为按行匹配 `/dev/vdX .* TYPE` 并复跑确认（菜单摘录逐行核对 SYS/DATA/UNK）。
- Concern 3：宿主 WSL 补装了 ntfs-3g（仅冒烟造盘用，非项目依赖）。

## 7. 验证命令（复跑）

```
"C:\Program Files\Git\bin\bash.exe" diskwipe-iso/build.sh
"C:\Program Files\Git\bin\bash.exe" diskwipe-iso/tests/run-all.sh        # 347 PASS
"C:\Program Files\Git\bin\bash.exe" --posix -n diskwipe-iso/src/*.sh diskwipe-iso/src/init
wsl -e bash /mnt/c/.../tmp/dw-smoke-v130.sh                              # qemu 冒烟 13/13 PASS
```
