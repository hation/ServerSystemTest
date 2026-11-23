# 计划：check-nvme-health.sh 多盘通用化改造

- 日期：2026-11-23
- 版本：v1
- 状态：待执行
- 前置：offline-stress-pkg/check-nvme-health.sh（v1 单盘模式，190 行）

## 背景

用户要求把 check-nvme-health.sh 完善得更健壮、支持全盘检查（不只 nvme2n1 单盘）。已确认设计：
- 检查范围：**NVMe + SATA 全盘**（枚举 /dev/nvme*n* 与 sd*/vd*/hd* 物理盘，排除分区）
- 结果呈现：**逐盘详细 + 末尾汇总表**
- 保留单盘指定：`bash check-nvme-health.sh nvme2n1` 只查单盘；无参数查全部
- 仍只读、命令缺失检测、颜色门控、结论判定

## 目标行为

1. **无参数**：自动枚举所有物理盘（NVMe nvme0n1~ + SATA sd[a-z]/vd*/hd*，用 lsblk -d 或 /sys 枚举，排除分区与 dm/loop），逐盘跑完整检查段。
2. **带参数**：`bash check-nvme-health.sh nvme0n1 nvme2n1 ...` 只查指定盘（支持多个，自动补 nvme 前缀逻辑保留但只对纯数字）。
3. **逐盘详细**：每盘输出 [1/5]~[5/5] 检查段（设备信息/SMART/nvme log/dmesg/文件系统）。
4. **汇总表**：末尾一张表：盘 | 结论（健康/异常/证据不足）| 关键字段摘要（SMART 严重命中数、I/O error 命中数、工具缺失数）。
5. **健壮性**：
   - 枚举的盘不存在（被参数指定）→ 明确提示"设备不存在"并计入汇总（证据不足/跳过）；
   - 无盘可查 → 提示"未发现任何物理盘"；
   - SATA 盘（sd*）smartctl 支持但不走 nvme smart-log（无 nvme 命令段）；
   - 命令缺失检测按盘类型分流（nvme 命令仅 NVMe 盘需要）；
   - 每盘独立结论，一盘异常不影响其它盘继续检查。

## 改动清单

### Task 1：重写 check-nvme-health.sh（多盘版）

- 结构：`main()` 解析参数 → `list_disks()` 枚举（无参数时）→ 对每盘 `check_one()`（现有 5 段逻辑抽取成函数）→ `summary()` 汇总表。
- 枚举函数：优先 `lsblk -d -o NAME,TYPE -J` 或 `lsblk -d -n -o NAME` 过滤 type=disk 且匹配 nvme*/sd*/vd*/hd*；回退 `/sys/block` 扫描。
- check_one：现 v1 的 5 段逻辑复用；按盘类型（nvme*/sd*）决定是否跑 nvme smart-log。
- 汇总表：收集每盘 critical/ioerr/unavailable 与结论，表格输出（固定宽度，非 tty 对齐）。
- 兼容 v1 用法：`bash check-nvme-health.sh`（默认全部）与 `bash check-nvme-health.sh nvme2n1`（单盘）都不破坏。

### Task 2：验证（桩模拟）

- `bash -n`。
- 桩模拟：
  - 场景 A：无盘（lsblk 桩输出空）→ "未发现任何物理盘"；
  - 场景 B：2 盘（nvme0n1 健康 + nvme2n1 异常[dmesg I/O error]）→ 逐盘详细 + 汇总表（健康/异常各一）；
  - 场景 C：指定单盘 nvme2n1 → 只查该盘；
  - 场景 D：指定不存在盘 nvme9n9 → "设备不存在"；
  - 场景 E：SATA 盘 sda（smartctl 正常、无 nvme 命令段）→ 健康；
  - 场景 F：工具全缺 → 汇总全"证据不足"。

### Task 3：文档同步

- 脚本头注释更新（多盘用法）。
- README/operation-manual 如提及该脚本则同步。

## 验证基准

- bash -n 通过
- 六场景桩模拟结论正确
- v1 单盘用法回归（无参数/单参数）

## 约束

- 不 git commit/add/stash
- 只读、无第三方依赖、纯 bash、set -u 不 set -e
- 不破坏 v1 单盘调用方式
