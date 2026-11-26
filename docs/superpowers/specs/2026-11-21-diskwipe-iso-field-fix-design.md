# diskwipe-iso v1.0.0 真机问题修复（乱码 + 系统盘未清除） 设计

- 日期：2026-11-21
- 状态：待评审
- 依据：用户 2026-11-21 真机测试反馈（v1.0.0 早期构建）+ brainstorming 澄清

## 1. 背景与问题

用户用 diskwipe-iso v1.0.0（早期构建）在真实服务器测试，反馈两个问题：

1. **界面乱码**：进入 iso 后菜单中文显示为乱码（终端 = **IPMI 虚拟 KVM**，走 VGA → Linux vt console）；乱码下用户看不清内容，盲操作回车，最终没看到"清除成功"关键词。
2. **系统盘未清除**：清理后用 **FirPE** 查看，业务盘已无数据（被清），但**系统盘仍有系统**（分区/系统还在）。

## 2. 已确认信息（brainstorming 澄清）

| 项 | 结论 |
|---|---|
| 终端 | IPMI 虚拟 KVM（VGA → Linux vt console）——**无 CJK 字体的确定性乱码场景** |
| iso | v1.0.0 早期构建（不确定具体 commit；能跑到菜单并清除业务盘，说明模块加载正常） |
| 系统盘确认 | 清理后**用 FirPE（Windows PE）查看**：系统盘有分区/系统，业务盘无数据 |
| 清除执行 | 业务盘被清 = 清除流程确实执行过 |

## 3. 根因分析

### 3.1 问题 1：乱码（确定性根因）

- 菜单全部输出中文 UTF-8；**Linux vt console（IPMI KVM 走 VGA 帧缓冲）默认字体不含 CJK 字形**，UTF-8 中文字节在无中文字体的 console 上显示为乱码/方框。
- 串口 SOL 若终端软件编码匹配可正常，但 IPMI KVM 场景**必然乱码**。
- 乱码导致用户看不清关键操作提示（默认全选/排除/YES 确认/每盘结果），是问题 1b（"回车即执行"）与问题 2（可能误操作）的**上游根因**。

### 3.2 问题 1b：乱码下"回车即执行"

- 代码层面：纯回车（`myn=""`）≠ `YES`，不会执行；用户实际是在看不清提示的情况下**盲操作**（可能输入了 YES 或误输入）。
- 修复不靠"猜用户做了什么"，而是**让关键提示在无中文字体的终端也可读**（ASCII），并保留 YES 门禁。

### 3.3 问题 2：系统盘未清除（两个疑点 + 待重测验证）

- 疑点 A（**误导因素，确定性**）：`wipe.sh`/`dw_wipe_disk` 只有 `umount → wipefs -a → wipefs -n`，**没有 partprobe**。wipefs 清了签名后内核分区表缓存仍是旧的；若清理后未重启直接看 `lsblk`/FirPE 前的内核视图，会看到旧分区 → 误判"还有系统"。**但用户用 FirPE 看**——FirPE 是新环境重新扫描磁盘，看到的是物理盘真实状态；若 FirPE 显示系统盘仍有分区，说明**系统盘确实未被 wipefs**（不是缓存误导）。
- 疑点 B（**真实清除路径**）：乱码下用户可能误操作——如输入了排除编号把系统盘排除、或盲输 YES 只对部分盘生效、或系统盘 wipefs 失败（被占用/设备忙）。当前无法从代码确定，**修复乱码 + 加强清除输出后可重测定位**。
- 待验证项：修复后重测，确认系统盘在列表中的显示、清除结果逐盘输出、FirPE 复查结果。

## 4. 目标

- **修复乱码**：菜单与清除结果的关键操作提示改为 **ASCII/英文**（无中文字体终端完全可读）；中文仅作辅助注释（乱码不影响操作）。
- **加强清除可靠性与可读性**：`wipefs -n` 验证后增加 `partprobe` 刷新内核分区视图（避免未重启看旧视图的误解）；每盘结果输出英文关键词（`OK ✓` / `FAIL ✗`）。
- **确认流程可读化**：将清除清单、YES 提示、退出提示全部 ASCII。
- 版本 v1.0.0 → **v1.2.0**（次版本 +1：乱码修复 + partprobe + 结果英文化）。

## 5. 非目标 / 反目标

- 非目标：不改清除算法（umount→wipefs→验证）与白名单；不做系统盘"保护"（系统盘业务盘都要能清，属设计口径）；不改为纯英文单语（保留中文辅助）。
- 反目标：
  - 乱码修复后**关键操作提示仍依赖中文**（必须 ASCII 可读）。
  - 增加 partprobe 不引入新依赖（util-linux 自带）；partprobe 失败不影响清除结论（仅提示）。
  - 不改变既有交互契约（默认全选/排除/YES/0 退出）与测试断言（除提示文案同步）。

## 6. 设计

### 6.1 屏幕全部用户可见行 ASCII 化（乱码修复，彻底化）

- **范围（builder-check 裁定）**：`src/menu.sh` 与 `src/wipe.sh` 的**所有用户可见输出行**——标题、表头、类型标注、交互提示、确认清单、**每盘结果（含失败原因）**、警告、反馈行（"已取消/未选择/输入结束/仅发现启动介质"等）——全部英文（纯 ASCII，无 CJK）。**中文仅保留在代码注释**，屏幕与日志文件统一英文操作行（可检索、测试断言统一）。
- 类型标注：`SYS`（系统盘）/ `DATA`（数据盘）/ `UNK`（未知）。
- 每盘结果（wipe.sh）：`OK /dev/sda reset to uninitialized` / `FAIL /dev/sdb: <english reason>`（原因英文：`umount failed: <mp>` / `wipefs -a failed` / `wipefs -n failed` / `signatures remain` / `not whitelisted`）。
- 标题：`DiskWipe Tool v<ver> — Reset disks to uninitialized`。
- 确认提示：`Will wipe the following N disks (irreversible!). Type YES to confirm:`；退出：`0 = exit (power off or reboot after done)`。
- **白名单防御性扩展（防系统盘命名漏列，builder-check 裁定）**：`dw_dev_ok` 与 `dw_enum_disks` 白名单从 `sd[a-z]`/`nvme[0-9]n[0-9]`/`mmcblk[0-9]` 扩展为 `sd[a-z]`+`sd[a-z][a-z]`（27+ 块盘）、`nvme[0-9][0-9]*n[0-9][0-9]*`、`mmcblk[0-9][0-9]*`（多位数字）。仍排除 `TRAN=usb` 与 `sr*`/`loop*`/`ram*`。

### 6.2 partprobe（清除后刷新内核分区视图，提前执行）

- **时机（builder-check 裁定）**：`src/lib.sh` `dw_wipe_disk` 在 `wipefs -a` 成功后**立即**执行 partprobe（无论后续 `wipefs -n` 验证结果如何），彻底消除"未重启看旧分区"误导路径。
  `"$PARTPROBE_BIN" "/dev/$ddev" >/dev/null 2>&1 || echo "WARN: partprobe failed (kernel partition view may be stale; effective after reboot)"`
  - partprobe 失败仅警告、不影响该盘结论。
  - 新增接缝变量 `PARTPROBE_BIN="${PARTPROBE_BIN:-partprobe}"`；`build-lib.sh` 拷贝工具清单补 `partprobe`（util-linux 同源）。

### 6.3 确认流程（保持 YES 门禁 + 可读）

- 维持：列盘 → 默认全选/排除 → 显示将清除清单（ASCII）→ `YES` 确认 → 清除 → 循环。
- 不增加新的确认层级（YES 门禁已够；乱码修复后提示可读）。

### 6.4 版本与打包

- `VERSION` 1.0.0 → **1.2.0**（保留 BOM 布局）。
- 重新 build.sh 出 iso（`output/diskwipe-v1.2.0.iso`）；qemu 冒烟复验（横幅 v1.2.0 + 菜单 ASCII + 虚拟盘清除 OK 输出）。

## 7. 测试计划（tests/，假件注入）

| 编号 | 场景 | 断言 |
|---|---|---|
| N1 | menu 输出 | **menu.sh 与 wipe.sh 的全部用户可见输出行不含 CJK 字符**（ASCII 校验；类型标注 SYS/DATA/UNK） |
| N2 | 类型标注 | 系统盘（PARTTYPENAME=EFI System）显示 SYS；数据盘显示 DATA；未知显示 UNK |
| N3 | wipe 结果输出 | `dw_wipe_disk` 成功输出 `OK /dev/<dev> reset to uninitialized`；失败输出 `FAIL /dev/<dev>: <english reason>` |
| N4 | partprobe | 清除时 `wipefs -a` 成功后调用 `partprobe /dev/<dev>`（无论验证结果）；partprobe 失败（假件返回 1）→ `WARN:` 提示但该盘结论不变 |
| N5 | partprobe 接缝 | PARTPROBE_BIN 指向假件时记录调用；生产默认 partprobe |
| N6 | 白名单扩展 | `sdab`/`nvme0n10`/`mmcblk10` 通过 `dw_dev_ok` 与 `dw_enum_disks`；`sdaa`（两位字母）亦通过；`sr0`/`loop0`/TRAN=usb 仍排除 |
| 回归 | 既有 t1-t4 全部保持 PASS（交互契约不变；文案断言同步英文） | — |

## 8. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 乱码修复不彻底（漏掉中文关键行） | N1 测试强制关键提示行 ASCII（grep 校验）；reviewer 逐行核 |
| partprobe 在 initramfs 不可用 | build 拷贝 partprobe（util-linux）；失败仅警告不阻断 |
| 系统盘未清根因未定 | 乱码修复后重测：用户看清列表与每盘结果；若系统盘仍未清，凭现场输出定位（届时再深挖） |
| 英文文案改变测试断言 | 回归套件断言同步（明确列出改动的期望） |

## 9. 文档与交付

- README：菜单交互示意更新为英文文案；说明乱码已修复（无中文字体终端可读）；partprobe 行为说明。
- 版本 v1.2.0 重打包。
- **交付后重测指引（用户执行）**：用 v1.2.0 iso → IPMI KVM 进 → 确认列表可读（含系统盘）→ 全选 → YES → 逐盘看 OK/FAIL → 重启后用 FirPE 复查系统盘与业务盘。若系统盘仍未清，把列表与结果拍照/记录给实现方。

## 10. 留给实现者的决定 / 设计者已定

- 设计者已定：菜单关键提示 ASCII 化；结果 `OK`/`FAIL` 前缀；partprobe 接缝（失败仅警告）；v1.2.0。
- 留给实现者：英文文案的具体措辞（简洁、无 CJK）；日志中英文分布；测试断言同步细节；build 拷贝 partprobe 的实现。
