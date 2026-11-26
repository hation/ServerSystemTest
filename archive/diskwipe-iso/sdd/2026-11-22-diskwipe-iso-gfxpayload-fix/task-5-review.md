# Task 5 review — v1.5.5 init 进度诊断 + timeout 兜底（commit d14b9b7）

**审查结论**：**Approved**（无 Critical / Important 问题，5 项 Minor，均不阻塞）

## 1. Spec 合规：✅

- **改动范围精确**：`git show d14b9b7 --stat` 确认仅 3 个文件变更——`diskwipe-iso/VERSION`、`diskwipe-iso/src/init`、`diskwipe-iso/tests/t3_init.sh`；禁止改动的 `menu.sh`/`lib.sh`/`wipe.sh`/build-lib.sh/isolinux/grub.cfg/embedded-efi.cfg/BOOTX64.EFI 全部未触碰。
- **init 三处改造与 brief 代码块逐字一致**：
  - 磁盘模块循环：`echo "loading module $im"` + `timeout 5 modprobe "$im" 2>/dev/null || echo "WARN: ..."` + 循环尾 `echo "Disk driver modules loaded"`，失败不再 `init_rescue`（原 69-71 行语义替换）；
  - 显卡循环：`echo "loading video module $gv"` + `timeout 5 modprobe "$gv" 2>/dev/null`（静默，无 WARN，符合 brief）；
  - mdev 首扫：`echo "device scan (mdev -s)"` + `timeout 5 mdev -s || echo "WARN: ..."` + `echo "Device nodes scanned"`。
- **保留项完整**：mount 三处 `init_rescue`、`init_rescue` 函数本身（仅 mount 用）、`sleep 2` + 3 轮 mdev 重试（内部同样包 `timeout 5 mdev -s`）、`exec menu.sh`。
- **注释**：头部与各步骤注释更新为 v1.5.5 语义（进度诊断 + timeout 兜底；D 状态用户态 timeout 无效、靠进度行定位），中文注释，LF 行尾（实测三个文件 CRLF=0、无孤立 CR）。
- **POSIX/ash**：无 bash 专属语法（无 `[[ ]]`/数组/`${var:0:3}`），`|| echo WARN` 短路模式与既有代码风格一致。
- **VERSION**：`1.5.4 → 1.5.5`（字节校验 6 字节 = `1.5.5\n`）。
- **构建产物**：`diskwipe-iso/output/diskwipe-v1.5.5.iso` 存在；build-v155.log 证实 kylin 模式、内核 4.19.90、iso 40M、initrd 内 `/diskwipe.version = 1.5.5`、src 四脚本 dash -n 0 错误、31 个未压缩 .ko。
- **验证脚本留档**：`tmp/dw-smoke-uefi-v155.sh` / `tmp/novid-v155.sh` / `tmp/dw-smoke-v155.sh` 均存在，且已按 v1.5.5 断言（进度行 loading module / loading video module / Disk driver modules loaded / Device nodes scanned）。

## 2. 代码质量

- **timeout 语义**：busybox `timeout 5` 超时返回 143（128+TERM）、命令失败返回其非 0 码、成功返回 0——`|| echo WARN` 的"失败/超时"语义正确；成功路径不误报。显卡循环无 `||` 静默跳过符合 brief。
- **rescue 语义变化风险评估（合理）**：
  - 磁盘驱动失败不再 rescue：保证到菜单，驱动缺失由 menu 盘列表（0 盘 → "Only boot media found"）体现——比 v1.5.4 失败即 rescue shell 更利于远程/无人值守场景定位，且 devtmpfs 已挂载（`mount -t devtmpfs`），mdev 失败对设备节点影响有限（内核自动建节点，mdev 仅补建）。
  - 挂载失败保留 rescue：符合 brief（"原 rescue 语义仅保留给 mount 失败"）。
- **进度行位置**：磁盘循环进度行在 fbcon 激活（显卡循环 bochs-drm/ast 加载后）之前打印——qemu A 经 serial 可见；真机 VGA 上依赖 fbcon 激活时重绘早期 VT 缓冲（真机 v1.5.4 已实证 fbcon 激活后 VGA 可见此前内核日志）。卡点若在磁盘循环内，进度行可定位；卡点在菜单磁盘扫描（D 状态）时只能定位到 `Device nodes scanned` 之后（menu.sh 禁止改动，属设计边界，brief 已接受）。
- **tests 适配（覆盖新语义）**：
  - fake `timeout`（`shift; "$@"`）不真等 5s、不污染 cmds.txt——实现干净；
  - I1 新增 6 项进度行断言（loading module ahci/mpt3sas、Disk driver modules loaded、loading video module bochs-drm、device scan、Device nodes scanned）；
  - I2 重写：mpt3sas 失败 → WARN 继续 + virtio_blk 仍加载 + mdev 4 次 + 最终 MENU_EXEC_MARKER，断言不再有 ERROR/rescue；
  - I4 新增：mdev 失败 → WARN 继续 + 完成行 + exec menu.sh；
  - I3（mount 失败 rescue）保持不变，验证 rescue 语义仅保留给 mount。

## 3. 报告证据真实性：✅（抽查全部通过）

- **qemu A**（`tmp/dw-smoke-uefi-v155.out`）：`fb0: bochsdrmfb frame buffer device`、`Console: switching to colour frame buffer device 128x48`、全部 `loading module` 进度行、`DiskWipe Tool 1.5.5`、`Disks found: 3 (vda vdb vdc)`、SYS/DATA/UNK、`OK x3`、`Exited.`、`Cleanup log saved to USB`、`Booting in blind mode`（INFO）——脚本 20 chk + 2 负面 = 22 项断言与 out 全部吻合，verdict PASS 真实。
- **qemu B**（`tmp/novid-v155.out`）：`Linux version 4.19.90`、`RAMDISK:`、`Run /init`、`loading module ahci`、`Disk driver modules loaded`、`Device nodes scanned` 全部出现，verdict PASS 真实。（见 Minor-1：报告断言数 ±1）
- **qemu C**（`tmp/dw-smoke-v155.out`）：`ISOLINUX 6.04`、`Loading /boot/vmlinuz... ok`、`Loading /boot/initrd.img...ok`、`DiskWipe Tool 1.5.5`、三盘、`OK x3`、`Exited.`、`Cleanup log saved to USB`、无 `GNU GRUB`/`ERROR`/`Only boot media`/`No writable log media`——脚本 18 chk + 4 负面 = 22 项全部吻合。
- **tests**（`tmp/runall-v155.log`）：t1:89 / t2:61 / t3:60（含 I1 新断言 6 项、I2 重写、I4 新增）/ t4:46 / t5:37 / t6:77，`==== 全部测试: ALL PASS ====`，与报告数字完全一致。
- **构建**（`tmp/build-v155.log`）：与报告 §2 关键行（kylin、4.19.90、iso 40M、initrd 内 version 1.5.5、dash -n 0 错误、31 个 .ko）逐字吻合。

## 4. 问题列表

### Critical
无。

### Important
无。

### Minor
1. **报告 B 断言数不精确**：`novid-v155.sh` 实际为 6 项必过断言（kernel started / initrd received / Run /init / loading module / Disk driver modules loaded / Device nodes scanned）+ 2 项 INFO（`Booting in blind mode` 与 `no suitable video mode found` 在 out 中均出现，脚本按 INFO 处理而非 PASS），报告称"7 项断言 PASS"±1。out 证据与 verdict PASS 真实，仅数字描述问题。
2. **显卡循环超时无提示**（Info 级）：若某显卡模块挂起 5s 被跳过，真机现场无任何 WARN——符合 brief 明确要求（显卡循环静默），仅备注。
3. **busybox timeout 对忽略 SIGTERM/D 状态进程兜底同样失效**（Info 级）：`timeout` 发 TERM 后 waitpid 等待子进程退出，进程不响应则 timeout 自身挂起——与头部注释"D 状态用户态 timeout 无效，靠进度行定位"一致，brief 已认知；`timeout -k` 强杀可增强但 brief 锁定格式，不改。
4. **3 轮重试 `timeout 5 mdev -s` 失败静默**（Info 级）：重试失败无提示，但首扫已有 WARN，语义可接受。
5. **mdev 失败仍打印 `Device nodes scanned`**（Info 级）：失败时完成行略具误导性，但 devtmpfs 已保证节点、brief 原文格式如此，不改。

## 5. concerns 合理性：✅

- D 状态 timeout 无效 → 靠进度行定位（最后停留行）——与 brief 注释一致，合理；
- mdev timeout 最坏额外耗时约 5s（首扫）+ 每轮 5s——正常路径无影响（qemu 实测通过），合理；
- iso 二进制不入库（.gitignore）——与既有版本一致，合理。

## 6. ⚠️ 无法从 diff 验证

1. **真机 VGA 上磁盘循环进度行的可见性**：磁盘循环在 fbcon 激活（显卡循环）之前打印，qemu 仅证明 serial 可见 + fb0 激活；真机 VGA 是否重绘早期 VT 内容（即磁盘循环进度行是否真的显示在 VGA 上）只能靠真机实测——这正是 brief"真机再测一次"的设计意图，非缺陷。
2. **B 报告断言数出入**：依据为脚本静态分析 + out 内容推断（报告未附 B 脚本输出原文）。
3. **构建断言**（40M 大小、31 个 .ko、dash -n）：基于 build-v155.log 文本，未重新执行构建。

## 结论

**Approved** — commit d14b9b7 精确符合 task-5 brief：改动仅限 init/VERSION/t3_init.sh，无越界；timeout/WARN 语义正确，rescue 语义收窄至 mount 合理；tests 适配覆盖新语义；A/B/C 三个 qemu 验证与 t1-t6 全部 PASS 的证据（out 文件、runall 日志、build 日志）抽查属实。5 项 Minor 均为报告措辞或 Info 级备注，不阻塞合入。
