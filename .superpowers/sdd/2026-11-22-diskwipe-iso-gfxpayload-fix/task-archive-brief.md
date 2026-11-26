# Archive brief — 归档 diskwipe-iso 方案代码

## 背景

用户决定放弃 diskwipe-iso（可启动 ISO 一键清盘工具）方案，要求把该方案代码归档到
`C:\Users\ganxin01\Documents\trae-work\ServerSystemTest\diskwipe-iso`（代码本就在此
目录），然后转向 FirPE + DiskGenius 一键清理方案。本任务：完成 git 归档（提交全部
改动 + 排除大文件 + 写归档文档）。

## 当前状态（已确认）

- 仓库根：`C:\Users\ganxin01\Documents\trae-work\ServerSystemTest`，main 分支
- HEAD=`036f943`（fix(diskwipe-iso): 恢复 megaraid_sas + 去 pci=realloc,nocrs——v1.6.0）
- 本地领先 origin/main 24 个 commit（未 push）
- 工作树未跟踪文件：
  - `.superpowers/`（SDD 工作区：task briefs/reports/reviews、progress.md）
  - `docs/superpowers/plans/*.md`、`docs/superpowers/specs/*.md`（设计/计划文档）
  - `diskwipe-iso/Kylin-Server-V10-SP3-2403-Release-20240426-x86_64-LD-3260.iso`
    （**4.6GB 官方 ISO 大文件，绝不入库，须 gitignore**）
  - `diskwipe-iso/tmp-official-cfg.sh`、`tmp-official-iso.sh`（本次排查临时脚本，不入库）
  - `tmp/`（大量历史测试脚本/构建日志，不入库——check 是否已有 gitignore）
  - 根目录 zip 包（offline-stress-pkg-*.zip 等）、sds-log-parser 等（其他项目，不入库）

## 任务（精确）

### 1. 检查并整理 .gitignore

读 `diskwipe-iso/.gitignore`（已有：output/、kylin-src/、kylin-src-*.tar.gz）。
仓库根 gitignore 若存在也读。**确保以下不入库**：
- `diskwipe-iso/Kylin-*.iso`（官方 4.6GB ISO）→ 加 `diskwipe-iso/*.iso` 或明确该文件名
- `diskwipe-iso/tmp-*.sh`（临时脚本）
- `tmp/`（若根 gitignore 未含则补）
- 已有 output/ 已忽略

### 2. 提交归档 commit（一次，含全部方案相关文件）

`git add`：
- `diskwipe-iso/`（src/、build-lib.sh、build.sh、VERSION、tests/、README、.gitignore 等，
  不含已忽略的大文件/临时脚本）
- `docs/superpowers/plans/2026-11-*.md`、`docs/superpowers/specs/2026-11-*.md`
  （diskwipe-iso 相关设计/计划文档）
- `.superpowers/sdd/2026-11-22-diskwipe-iso-*/`（SDD 工作区全部：briefs/reports/
  reviews/progress.md/task-*.report.md 等）

commit message：
`docs(diskwipe-iso): 归档方案（放弃可启动 ISO 一键清盘路线，转 FirPE+DiskGenius）——提交全部代码/设计文档/SDD 记录，排除官方 ISO 大文件与临时脚本`

### 3. 写归档文档 `diskwipe-iso/ARCHIVE.md`

记录（中文）：
- **方案概述**：可启动 ISO 清盘工具（替代 FirPE+DiskGenius 现场清盘流程），开机列盘→
  输入 YES→wipefs 一键恢复硬盘为未初始化
- **技术路线**：BIOS(ISOLINUX)+UEFI(精简 GRUB) 双引导 + Kylin 4.19 内核（解决 Ubuntu
  内核 USB 不兼容）+ initramfs（busybox + util-linux wipefs/lsblk/blkid）+ 全 ASCII
  屏幕（IPMI KVM 无中文字体）+ 日志落内存/退出写 U 盘
- **版本演进**：v1.0.0 → v1.6.0 关键里程碑（v1.1.0 日志落U盘、v1.4.0 Kylin 内核、
  v1.5.0 ISOLINUX 重构根治盲模式卡死、v1.5.6 唯一真机识别 SAS 盘成功、v1.6.0 恢复
  megaraid_sas）
- **未解决核心问题**：真机 SAS 盘（447GiB，LSI/Broadcom 0x1000 控制器）在**内核 PCI
  枚举阶段**未被发现（DIAG SAS 空、无 mpt3sas_cm0、lsblk 只有 U 盘）；多轮修复
  （rescan/max_queue_depth/去 megaraid_sas/回退 v1.5.6/pci=realloc,nocrs/恢复
  megaraid_sas 均无效）；v1.5.6 曾成功（mpt3sas_cm0 port enable SUCCESS），判定为
  **PCIe 链路/固件枚举层问题，软件不可解**（Nenad Lazić 权威：设备不在 lspci 中
  OS 不是问题）
- **放弃结论**：Linux 内核枚举 PCI 设备问题无法在工具层解决；转向 FirPE（Windows PE，
  厂商驱动枚举可靠）+ DiskGenius 命令行清盘方案
- **归档说明**：代码全部提交至 git（HEAD=036f943），大文件（官方 ISO/kylin-src）不入库
  本地保留，未来如需恢复可基于 git 历史

### 4. 不 push（用户未要求 push；本地 ahead 24 保留）

## 禁止

- 不提交大文件（官方 ISO 4.6GB、kylin-src、output/ 等）
- 不改代码逻辑（纯归档，零代码修改）
- 不删除任何本地文件（只 gitignore 排除）

## 验证

- `git status` 干净（只剩被 ignore 的未跟踪文件）
- `git log -1` = 归档 commit
- `git ls-files diskwipe-iso/` 不含 *.iso / tmp-*.sh / output/ / kylin-src/
- ARCHIVE.md 存在且内容完整

## 报告

写 `task-archive-report.md` 到 `.superpowers/sdd/2026-11-22-diskwipe-iso-gfxpayload-fix/`：
提交的 commit hash、git ls-files 验证输出、ARCHIVE.md 摘要。
返回：状态、commit hash、一行摘要、concerns。