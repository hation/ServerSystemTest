# Archive-brief — 归档 diskwipe-iso 旧方案文档（隔离新工具开发）

## 背景

用户决定放弃 diskwipe-iso（可启动 ISO 清盘工具）方案，转向 FirPE + diskpart 新工具。
要求：把旧方案的问题/设计文档归档到一个独立归档文件夹，避免干扰新工具开发。
（diskwipe-iso/ 代码目录此前已 git 归档 commit c7a1bdb，含 ARCHIVE.md，本次只归档
**文档与 SDD 记录**。）

## 当前相关文件（已确认）

- plans（5）：docs/superpowers/plans/2026-11-2{1,2}-diskwipe-iso*.md
- specs（6）：docs/superpowers/specs/2026-11-2{1,2}-diskwipe-iso*.md
- sdd（2 目录）：.superpowers/sdd/2026-11-22-diskwipe-iso-gfxpayload-fix、
  .superpowers/sdd/2026-11-22-diskwipe-iso-scan-hang
- **保留不动**：docs/superpowers/plans/2026-11-26-firpe-diskgenius-cleanup-design.md
  （新方案文档）、diskwipe-iso/ 代码目录、docs 中与 offline-stress-pkg 相关的
  （2026-11-21-hdd-cleanup*、2026-11-23-disk-map.md 等非 diskwipe 方案文件不归入）

## 任务（精确）

### 1. 创建归档结构
```
archive/diskwipe-iso/
  plans/    ← 移动 5 个 plans（2026-11-21-diskwipe-iso*.md、2026-11-22-diskwipe-iso-*.md）
  specs/    ← 移动 6 个 specs（2026-11-21-diskwipe-iso-*design.md、2026-11-22-diskwipe-iso-*design.md）
  sdd/      ← 移动 2 个 SDD 工作区目录（gfxpayload-fix、scan-hang，含全部 briefs/reports/reviews/progress.md）
  README.md ← 归档说明（方案概述、为何放弃、代码归档位置 diskwipe-iso/ + ARCHIVE.md、文档索引）
```

### 2. 移动（git mv 保留历史；sdd 被 .superpowers/sdd/.gitignore 忽略需 git add -f）
- 用 `git mv` 移动 docs/superpowers/plans|specs 下 11 个文件到 archive/diskwipe-iso/plans|specs
- 用 `mv`（文件系统）+ `git add -f` 移动 2 个 sdd 目录到 archive/diskwipe-iso/sdd/
  （注意 .superpowers/sdd/.gitignore 含 `*`，需 -f 强制跟踪归档内容）
- 写 archive/diskwipe-iso/README.md

### 3. 一次 commit
message：`docs(diskwipe-iso): 归档旧方案文档与 SDD 记录至 archive/diskwipe-iso/（隔离新 FirPE+diskpart 工具开发，代码归档见 diskwipe-iso/ARCHIVE.md）`

## 禁止

- 不改任何代码、不改新方案文档（2026-11-26-firpe-diskgenius-cleanup-design.md）
- 不删文件（只移动）
- 不碰 offline-stress-pkg 相关文档（hdd-cleanup/disk-map）

## 验证

- git status 干净（仅被 ignore 未跟踪）
- archive/diskwipe-iso/{plans,specs,sdd} 存在且文件数正确（plans 5 + specs 6 + sdd 2 目录）
- 新方案文档仍在 docs/superpowers/plans/ 下
- git log -1 = 归档 commit

## 报告

写 task-archive2-report.md 到 archive/diskwipe-iso/sdd/2026-11-22-diskwipe-iso-gfxpayload-fix/
返回：状态、commit hash、一行摘要、concerns。