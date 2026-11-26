# Task 6 review — v1.5.6 显卡循环只留 ast + 进度改 /dev/kmsg

审查对象：commit `3f70526`（相对 BASE `d14b9b7`，4 files changed, 71 insertions(+), 41 deletions(-)）
审查方式：只读。对照 brief、报告、diff，并抽查 tmp/ 下构建/测试/冒烟证据。

---

## 一、Spec 合规：✅

diff 精确符合 brief，无越界：

| brief 要求 | diff 实现 | 判定 |
|---|---|---|
| 1a) dw_progress 新增于文件头部、PATH 设置后 | init 第 27-29 行，`export PATH` 之后、`. lib.sh` 之前，实现与 brief 逐字一致（`echo "diskwipe-init: $*" > /dev/kmsg 2>/dev/null`） | ✅ |
| 1b) 磁盘循环 loading module / Disk driver modules loaded 改 dw_progress | init 第 77、80 行；timeout 5 + WARN 继续不变 | ✅ |
| 1c) 显卡循环只保留 ast | init 第 87-88 行：for 循环删除，仅 `dw_progress "loading video module ast"` + `timeout 5 modprobe ast 2>/dev/null`，附 D 状态根因注释 | ✅ |
| 1d) mdev 两行进度改 dw_progress | init 第 91、93 行 | ✅ |
| 2) build-lib.sh DW_KYLIN_MODULES 只留 ast + 原因注释 | build-lib.sh 第 67-73 行：移除 mgag200/smifb/bochs-drm/cirrus/virtio-gpu，注释与 init 一致 | ✅ |
| 3) VERSION 1.5.6 | ✅ | ✅ |
| 4) 重新构建 | output/diskwipe-v1.5.6.iso 存在（39M，构建日志支持） | ✅ |
| 禁止改动（menu.sh/lib.sh/wipe.sh/isolinux/grub.cfg/embedded-efi.cfg/BOOTX64.EFI/xorriso） | diff 仅 4 文件：VERSION、build-lib.sh、src/init、tests/t3_init.sh（t3 为 brief 明确允许） | ✅ |
| tests 适配（断言 dw_progress 调用） | t3 用 `bash -x` + `BASH_XTRACEFD=3` 分流 xtrace 正向断言 dw_progress 调用与 kmsg 载荷，符合 brief「断言 dw_progress 调用」选项 | ✅ |

## 二、代码质量

- **dw_progress**：`$*` 引号内合并参数、`2>/dev/null` 静默失败，POSIX/ash 兼容（busybox ash 经 qemu A/B/C 实测）；写失败不中断启动语义正确（t3 恰好覆盖该路径）。
- **显卡循环**：只留 ast 正确，与 build-lib 白名单一致（`DW_KYLIN_MODULES` = init Kylin `DRIVE_MODULES` + ast），两端注释同源。
- **白名单一致性**：✅ init Kylin 磁盘清单与 build-lib `DW_KYLIN_MODULES`（去 ast）逐项一致。
- **POSIX 语法**：无 bash 专属语法；`dash -n` 0 错误（构建日志）。
- **t3 适配合理性**：✅ Git Bash /dev 虚拟只读无法建 /dev/kmsg 假件，xtrace 断言方式等价满足 brief 选项；真实写路径由 qemu A/B/C 端到端覆盖（kmsg → printk → serial）；stdout 纯 console 断言（`check_not_out 'diskwipe-init:'`）+ `modprobe ast` 在/5 个显卡驱动不在，均有效。

## 三、报告 concerns 评估

1. **qemu A 无 fb0 适配**：✅ 合理且证据支持。qemu `-vga std` 为 bochs 兼容显卡，v1.5.5 的 fb0 来自 bochs-drm；v1.5.6 initrd 只打包 ast，qemu 无 ast 硬件 → 无 fbcon（A 输出证实：仅 `Console: colour dummy device 80x25` + `console [tty0] enabled`，无 fb0/efifb）。真机 AST2500 由 ast 提供 fbcon（保留 ast 驱动 + v1.5.5 真机实证），不受影响。brief 的 fb0/Console switching 两项放宽为 INFO 属合理适配（修复本意即移除 bochs-drm，qemu 必然无 fb0），已充分披露。
2. **CRLF 基线**：⚠️ **事实性描述不准确**。实测（python 二进制读）：基线与当前工作区的 init/build-lib.sh/t3_init.sh 均为 LF（CRLF=0，无 BOM），git 对象同样为 LF。即行尾实际无问题、符合 brief「LF 行尾」要求，但 concern 2 声称「仓库基线各文件即为 CRLF」与实测不符，措辞需修正（结论「保持与基线一致未改行尾」仍成立）。
3. **t3 kmsg 断言方式**：✅ 合理（见二），xtrace 断言载荷 `+ echo 'diskwipe-init: ...'` 同时证明 dw_progress 被调用且载荷正确。

## 四、证据真实性抽查：✅ 全部属实

- `git log`：`3f70526` 存在，stat 与报告一致（4 files, 71+/41-）。
- `tmp/build-v156.log`：Kylin 4.19 内核、**26 个 .ko.xz（v1.5.5 为 31，差 5 = 移除的 5 个显卡种子，数学一致）**、initrd 5.0M、iso 39M、`/diskwipe.version = 1.5.6`、dash -n 0 错误、isoinfo 全过。
- `tmp/runall-v156.log`：t1-t6 全部 ALL PASS（t3 67 项，含 6 类 kmsg 载荷、ast 唯一、5 个显卡不在、stdout 无 diskwipe-init:）。
- `tmp/dw-smoke-uefi-v156.out.clean`：kmsg 进度行全出现（`[37.28s] diskwipe-init: loading module ahci` … `loading video module ast` … `Device nodes scanned`）；无 fb0/efifb（证实 concern 1）；全流程 1.5.6/三盘 SYS-DATA-UNK/OK x3/Exited/Cleanup log saved to USB；无 ERROR/Only boot media。
- `tmp/novid-v156.out`：blind mode 打印（脚本按 brief 判 INFO）+ 内核启动 + kmsg 进度行。
- `tmp/dw-smoke-v156.out.clean`：ISOLINUX 6.04、Loading /boot/vmlinuz... ok、kmsg 进度行；keylines 含 1.5.6 日志内容（三盘 OK x3）。
- 验证脚本三份留档：`tmp/dw-smoke-uefi-v156.sh` / `novid-v156.sh` / `dw-smoke-v156.sh`。

## 五、问题列表

- **Critical**：无
- **Important**：无
- **Minor**：
  1. 报告 concern 2 声称基线为 CRLF，实测为 LF（行尾实际合规，纯陈述错误，需修正报告措辞）。
  2. brief 验证项「fb0 + Console switching」被放宽为 INFO（偏离字面验证标准，但技术依据充分、已披露；建议后续 brief 同步）。
  3. `novid-v156.sh` 头注释写「不应出现 Booting in blind mode」，断言实际为 INFO（允许打印）——脚本注释与行为不一致，无功能影响。

## 六、⚠️ 无法从 diff 验证

- 「initrd 解包实检：gpu/drm 目录只剩 ast + drm/drm_kms_helper/ttm」——需解包 iso；构建日志（26 个 .ko、31→26）间接支持，逻辑上成立（白名单+依赖链机制不会带入其余显卡驱动）。
- 「真机 AST2500 显示不受影响」——本任务无真机验证，属合理推断（ast 保留 + v1.5.5 真机实证）。

## 结论：**Approved**

改动精确符合 brief、无越界；dw_progress/显卡循环/白名单/t3 适配质量良好；A/B/C + tests 证据真实完整。仅报告 concern 2 的 CRLF 陈述有误（实际 LF，行尾无问题），不阻塞合入。
