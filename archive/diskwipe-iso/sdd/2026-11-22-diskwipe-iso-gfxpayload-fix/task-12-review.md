# Task 12 review — v1.5.12 枚举诊断 + 勾选兜底 + reboot 强制（含 Task 11）

- 审查对象：commit `4c22a7f` vs BASE `f3e100e`（6 文件 +261/-41，与报告一致）
- 审查方式：只读；diff 核对 + 源码上下文核对（lib.sh/menu.sh/init/tests）+ 运行日志证据抽查

## Spec 合规：✅

1. **改动范围**：`git diff f3e100e 4c22a7f --stat` = 6 文件：VERSION、src/init、src/menu.sh、tests/t2_menu.sh、tests/t3_init.sh、tests/t6_scan.sh。lib.sh / wipe.sh / build-lib.sh / isolinux / grub.cfg / embedded / BOOTX64.EFI / xorriso 零改动（与报告"禁止改动确认"一致）。
2. **menu.sh 交互逻辑**：列盘/排除编号/YES 二次确认/0 退出/清除后循环全部未动；唯一逻辑改动集中在 brief 指定的三处（RAW enum 诊断行、勾选兜底、reboot -f + fallthrough）+ Task 11 的 stdin 重定向与重试 3→6（brief 明确包含 Task 11）。其余为注释更新。
3. **三处实现与 brief 代码块逐字一致**：
   - 诊断行位于 `ml="$(dw_enum_disks)"`（含失败重试）之后、`[ -z "$ml" ]` 检查之前（menu.sh:112），kmsg 载荷 `diskwipe-init: RAW enum ml=[...]`，正常流程零影响。
   - 兜底块（menu.sh:252-255）：`sed -n "${mi}p"` + `${mtabline%%|*}`，POSIX/ash 合规；`$mtab` 由 `dw_format_disk_lines` 生成（awk 不删行），行号与 `$ml` 一一对应，`mi` 在勾选循环与列盘循环中同步递增，排除行 continue 但 mi 仍递增——对应关系正确。
   - reboot 段（menu.sh:128-137）：`sleep 10` → `reboot -f 2>/dev/null || true` → `sleep 2` → `dw_progress "reboot ineffective, re-enumerating"` → `continue`。
4. **VERSION** `1.5.10 → 1.5.12`（跳 1.5.11 未发布，brief 明确）。
5. **commit**：一次 commit `4c22a7f`，message 与 brief 提交要求逐字一致。
6. **POSIX/中文注释**：全部通过（无 `[[ ]]`/数组/`${var:0:3}`；`$(( ))`、`sed -n`、`|| true` 均 busybox ash 兼容；注释中文、用户可见行 ASCII）。

## 验证证据真实性抽查：✅

- `tmp/run-a-v1512.log`：RAW enum ml=（含 vda vdb vdc）、DiskWipe Tool 1.5.12、Disks found: 3 (vda vdb vdc)、OK x3、Exited、WARN 降级、loading HID drivers (usbhid)，无 ERROR/Only boot media——与报告一致。
- `tmp/run-b-v1512.log`：Only boot media found、retry 4/6..6/6、`RAW enum ml=[]`（无盘空枚举）、no disks after retries, rebooting in 10s、reboot -f 生效——与报告一致。
- `tmp/run-c-v1512.log`：ISOLINUX 6.04 / Loading / initrd.img...ok / 21 项断言全 PASS / smoke verdict: PASS。
- `tmp/runall-v1512c.log`：t1:89、t2:86、t3:96、t4:50、t5:37、t6:77，全部失败 0 项，`==== 全部测试: ALL PASS ====`——与报告一致。
- `output/diskwipe-v1.5.12.iso` 存在。

## 问题列表

### Critical：无

### Important：无

### Minor
1. **fallthrough 死循环（设计固有，建议知悉）**：`dwnoretry` 在 `continue` 后不重置。若 `reboot -f` 无效且盘始终不就绪，则每 ~17s（sleep 10 + reboot -f + sleep 2 + 1 次枚举）无限循环刷 "no disks after retries / reboot ineffective"，与注释"避免反复 reboot 空转"的措辞略有出入（实际是每 17s 重试一次 reboot）。属 brief 指定实现的固有属性，且每次循环重新枚举、盘就绪即恢复；系统处于 reboot 失效的病态时这是唯一合理防御（避免带空 `$ml` 落入列盘段产生假盘行 `Disks found: 1 ()`——正是 v1.5.11 真机症状）。如需收敛可重置 `dwnoretry=0` 或限制 fallthrough 轮数，但超出 brief 范围，仅记录。
2. **兜底仍为空时的计数细节**：兜底后 mdev 仍为空（仅当 mtab 行数 < ml 行数的理论边界，实际不可能——格式化 awk 不删行）时，`msel` 会拼入空串（尾部空格，wipe 传参无害）且 `mcnt` 多计，与注释"该行放弃"的表述有微小出入；全空时有 `No disks selected` 保护。真实场景（mtab 对应行恒存在且首字段为设备名）不受影响。
3. **`exec 0< /dev/tty0` 无打开失败保护（Task 11）**：`[ -e /dev/tty0 ]` 通过但 open 失败（内核无 VT 等极端环境）→ POSIX sh 直接退出 → menu.sh 为 PID1，退出即内核 panic。真机（KVM 有 VT）与 qemu A/B 均已实测通过，属理论边界；如需更稳可 `exec 0< /dev/tty0 2>/dev/null || :`（超出本 commit 范围）。
4. **M11 用例环境依赖**：`run_menu` 的 mode=tty0 分支以宿主 `/dev/tty0` 是否存在决定走 unshare+tty0 还是 fallback 管道分支；在无 /dev/tty0 的环境（如 Git Bash）M11 会静默降级为 fallback 语义测试且断言仍过（假阳性）。报告声明 WSL 下运行（/dev/tty0 存在），实际已验证 tty0 分支——仅在非 WSL 环境复跑时需注意。
5. **M12 用例复制实现片段**：因标准假 lsblk 无法注入"设备字段空"枚举行，M12 直接复制 menu.sh 的兜底片段做单元验证，存在实现与测试漂移风险（menu.sh 兜底逻辑后续改动时 M12 可能仍过）。当前可接受的替代方案。
6. **报告缺具体 commit hash**：report 文末仅写"hash：见提交输出"，未给出 4c22a7f（git log 已确认）。属报告完备性小瑕疵。

## 报告 concerns 合理性：✅

1. **sendkey 时序**（A 首轮 FAIL）：qemu 8.2 HMP 首条命令可能被初始化窗口吞掉 + 菜单 read 阻塞前注入无效——drain 初始 banner + 等 `"> "` 提示再注入，合理且已由 A 连续 PASS 佐证。
2. **BIOS usb-kbd 改 i8042**：qemu xhci BIOS 路径 `couldn't allocate usb_device` 是 qemu 侧资源分配问题，改 `-nographic -serial file:` + PS/2 sendkey 注入仅验证引导链+菜单流程，PS/2 等价性说明充分；C 21 项回归全 PASS 佐证。
3. **t6 H7 LOG_DIR 隔离**：根因链完整成立——run-all 前序用例（t1-t5 正常 menu 调用）在秒级时间戳窗口留下的 `/tmp/diskwipe-log/diskwipe-<秒>.log` 与 H7 的 `LOG_FILE` 同名 → `dw_save_log_to_usb` 的 `[ -f "$LOG_FILE" ]` 误判命中残留 → 多执行一次 lsblk（3 次 vs 期望 2 次）；隔离后 H7 假 timeout 恒 124 → tee 未执行 → 文件未创建 → 返回 1 不新增枚举。修复正确（t6_scan.sh +6/-1）。

## ⚠️ 无法从 diff 验证

- qemu A/B/C 的实测（-vga std 有盘全流程 / -vga none 无盘 reboot -f / BIOS 21 项）依赖虚拟化环境运行结果，仅能从留档日志抽查确认（已抽查，证据一致）；重跑需在 WSL + qemu 环境执行 `tmp/dw-smoke-uefi-v1512.sh` / `tmp/novid-v1512.sh` / `tmp/dw-smoke-v1512.sh`。
- `output/diskwipe-v1.5.12.iso` 内 initrd 模块/版本内容（报告"构建关键行"）基于 isoinfo 校验输出，diff 层面不可见，日志未逐行复核（构建产物存在、大小 40894464 B 与报告 39M 相符）。

## 结论：Approved

实现与 brief 精确一致，无越界改动；交互逻辑零改动；POSIX 合规；A/B/C + t1-t6 全部验证证据真实充分。Minor 项均为理论边界/测试环境依赖，不阻断合入。
