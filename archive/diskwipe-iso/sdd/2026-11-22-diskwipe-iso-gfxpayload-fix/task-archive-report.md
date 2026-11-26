# Task archive 报告 — diskwipe-iso 方案 git 归档

## 状态
DONE（归档完成：.gitignore 整理 + 一次归档 commit + ARCHIVE.md；未 push）

## commit hash
`c7a1bdb`（main HEAD；114 files changed, 12740 insertions(+)，仅新增/文档，零代码逻辑改动）

commit message：
`docs(diskwipe-iso): 归档方案（放弃可启动 ISO 一键清盘路线，转 FirPE+DiskGenius）——提交全部代码/设计文档/SDD 记录，排除官方 ISO 大文件与临时脚本`

## 提交内容
1. `diskwipe-iso/`：代码/测试已随 036f943（v1.6.0）在库；本次新增 `ARCHIVE.md`（111 行）+ `.gitignore` 修改（4 行新增：`*.iso`、`tmp-*.sh`）。
2. 新建仓库根 `.gitignore`：`tmp/`。
3. `docs/superpowers/plans+specs` 未跟踪的 12 个 2026-11-*.md（diskwipe-iso 系列 + hdd-cleanup + disk-map，均为此前工作树遗留设计/计划文档）。
4. `.superpowers/sdd/2026-11-22-diskwipe-iso-gfxpayload-fix/` 与 `2026-11-22-diskwipe-iso-scan-hang/` 两个 SDD 工作区全部（briefs/reports/reviews/progress.md/final-review.md 等；因 `.superpowers/sdd/.gitignore`（`*`）忽略，用 `git add -f` 强制添加）。

## 验证输出
- `git log -1`：`c7a1bdb docs(diskwipe-iso): 归档方案（放弃可启动 ISO 一键清盘路线，转 FirPE+DiskGenius）……` ✅
- `git ls-files diskwipe-iso/`（19 个）：`.gitignore`、`ARCHIVE.md`、`README.md`、`VERSION`、`build-lib.sh`、`build.sh`、`kylin-kernel-export.sh`、`src/{init,lib.sh,menu.sh,wipe.sh}`、`tests/{lib.sh,run-all.sh,t1_wipe.sh,t2_menu.sh,t3_init.sh,t4_log.sh,t5_ascii.sh,t6_scan.sh}` —— **不含任何 `*.iso` / `tmp-*.sh` / `output/` / `kylin-src/` / `kylin-src-*.tar.gz`** ✅
- `git status`：工作树仅剩未跟踪文件 = 全部为「其他项目不入库」类（offline-stress-pkg-*.zip、sds-log-parser、sds_extract、test-souce-data、tmp-ocr.ps1、`.superpowers/offline-stress-pkg.zip`）；diskwipe-iso 大文件与临时脚本已全部被 ignore 不再显示 ✅
- ignore 生效确认：`check-ignore` 命中 `diskwipe-iso/*.iso`（4.6GB 官方 ISO）、`diskwipe-iso/tmp-*.sh`、根 `tmp/`、既有 `kylin-src-*.tar.gz`（445M）、`output/` ✅

## ARCHIVE.md 摘要（diskwipe-iso/ARCHIVE.md）
- **方案概述**：可启动 ISO 清盘工具，替代 FirPE+DiskGenius 现场清盘；开机列盘→默认全选→输入 YES→`wipefs -a` 一键恢复硬盘为未初始化；三条安全边界（只清分区表+签名、不清数据块、不清 SMART）。
- **技术路线**：BIOS(ISOLINUX)+UEFI(精简 GRUB) 双引导 + xorriso 手动打包 + Kylin 4.19 内核 + initramfs（busybox + util-linux wipefs/lsblk/blkid + partprobe）+ 全 ASCII 屏幕 + 日志落内存/退出写 U 盘 + WSL 一键构建 + 400+ 假件单测。
- **版本演进 v1.0.0→v1.6.0**：关键里程碑表（v1.1.0 日志落 U 盘、v1.2.0 ASCII 化、v1.3.0-1.3.3 列盘/日志/枚举卡死修复、v1.4.0 Kylin 内核、v1.5.0 ISOLINUX 重构、v1.5.3 serial 兜底、v1.5.4 显卡 DRM、v1.5.6 唯一真机识别 SAS 盘成功、v1.5.9 去 usb-storage 系统正常启动、v1.5.13 去自动关机安全修复、v1.5.15-1.5.29 多轮 SAS 修复尝试、v1.6.0 ISO 解包对比后回 v1.5.6 配置），均附 git commit。
- **未解决核心问题**：真机 SAS 盘（447GiB，LSI/Broadcom 0x1000 控制器）在内核 PCI 枚举阶段未被发现（DIAG SAS 空、无 mpt3sas_cm0、lsblk 只有 U 盘）；v1.5.6 曾成功（mpt3sas_cm0 port enable SUCCESS）但为概率事件；rescan/max_queue_depth/去 megaraid_sas/回退 v1.5.6/pci=realloc,nocrs/恢复 megaraid_sas 均无效；判定 PCIe 链路/固件枚举层问题软件不可解（设备不在 lspci 中 OS 不是问题）。
- **放弃结论**：Linux 内核枚举 PCI 设备问题无法在工具层解决，转向 FirPE（Windows PE 厂商驱动枚举可靠）+ DiskGenius 命令行清盘。
- **归档说明**：代码全部提交（最后功能 commit 036f943=v1.6.0 + 本归档 commit c7a1bdb）；大文件（官方 ISO 4.6GB/kylin-src 996M/kylin-src tar.gz 425M/output）不入库本地保留；SDD 记录为恢复方案的一手资料。

## 一行摘要
归档完成：gitignore 排除官方 ISO（4.6GB）/临时脚本/tmp，一次 commit（c7a1bdb，114 文件）提交全部代码+设计文档+SDD 记录并写 ARCHIVE.md，未 push（本地领先 origin/main 25）。

## concerns
1. `.superpowers/sdd/.gitignore`（`*`）会忽略 sdd/ 下全部内容，本次用 `git add -f` 强制提交两个 diskwipe-iso SDD 目录——若未来新增 SDD 记录需注意同样走 `-f` 或调整该 gitignore。
2. `git status` 仍显示若干未跟踪文件（offline-stress-pkg-*.zip、sds-log-parser、sds_extract、test-souce-data、tmp-ocr*.ps1、`.superpowers/offline-stress-pkg.zip`）——按 brief「其他项目，不入库」未提交也未 ignore，如需彻底干净可后续补根 .gitignore。
3. 提交了 `docs/superpowers/plans/2026-11-23-disk-map.md` 与 `2026-11-21-hdd-cleanup*`（brief 任务 2 清单中的 2026-11-*.md，且 brief「当前状态」将其列为工作树文件；严格属 offline-stress-pkg 而非 diskwipe-iso，如不需要可后续剔除）。
