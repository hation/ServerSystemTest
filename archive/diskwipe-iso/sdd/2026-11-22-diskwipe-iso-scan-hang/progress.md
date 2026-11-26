# SDD ledger — plan: docs/superpowers/plans/2026-11-22-diskwipe-iso-scan-hang.md

BASE: f5a8ce2（main HEAD，diskwipe-iso v1.2.0）

## Preflight scan（任务间共享文件/接口）

| 任务对 | 共享/接口 | 发现 |
|---|---|---|
| Task1 ↔ Task2 | Task2 消费 Task1 的批量探测/超时实现（依赖 build 后 busybox timeout applet 可用）；共享 VERSION（Task2 改 1.3.0） | 无冲突 |
| Task1 内部 | 批量探测（dw_scan_system_disks）→ menu 列盘查表（零 exec）；timeout 接缝覆盖 lib.sh 三处 + init 一处 | 接口一致 |

## Task progress

- Task 1: complete (commit 4cfbd16, review clean — Spec ✅ / quality Approved)
  - 347 PASS（t1-t6：89/61/44/50/37/66）；`--posix -n` 0 错误；列盘四循环零 exec、timeout 覆盖完整且清除未误加、枚举超时降级、init 路径生效、blkid -o full 假件形态一致。
  - deferred minors: (1) H1 回归防护盲区（假件不记录逐盘探测，建议假件补记录封死）。(2) 确认循环 dw_log 逐行 tee（既有行为）。(3) mtype 子 shell fork（无外部 exec）。均不阻塞。

## Rulings

- 无预检裁定（既有约定直接适用：R2 提交不含 .superpowers；tests 随工具入库）。

## Task progress

（待 Task 1 完成填充）
