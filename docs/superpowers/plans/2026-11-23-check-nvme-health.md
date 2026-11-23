# 计划：nvme2n1 故障盘一键检查脚本

- 日期：2026-11-23
- 版本：v1
- 状态：待执行

## 背景

test-mission-7 stress-test-6 的 nvme2n1 盘在压测期间出现真实 I/O 故障（print_req_error → ext4 journal 中止 → superblock 写失败，exitcode=1）。用户需要在服务器现场检查该盘的健康状态。交付一个**一键检查脚本**，用户拷贝到服务器执行，输出结构化结论。

## 目标

- 单一脚本 `check-nvme-health.sh`（可 `bash check-nvme-health.sh` 或 `bash check-nvme-health.sh nvme2n1` 直接执行）。
- 检查项：
  1. 设备基本信息（lsblk / nvme list，若可用）
  2. **SMART 健康**（smartctl -a /dev/<dev>，重点字段：Critical Warning、Media Errors、Percentage Used、Temperature）
  3. NVMe 厂商日志（nvme smart-log，若可用）
  4. 内核 dmesg 故障记录（dmesg -T | grep -iE 'nvme2n1|print_req_error|I/O error|Buffer I/O' 过滤当前盘）
  5. 文件系统/挂载状态（mount、设备状态 ro/rw）
  6. **结论判定**：根据 SMART 关键字段 + dmesg 是否命中 I/O error，输出 健康 / 异常（需换盘/返修）/ 需人工判断
- 命令缺失检测：smartctl/nvme 不存在时明确提示安装命令，不中断其它检查。

## 约束

- 纯 shell（bash），无第三方依赖，与 offline-stress-pkg 风格一致。
- 默认设备 nvme2n1，支持 `$1` 覆盖。
- 只读检查，**不执行任何修复/格式化**（fsck 仅提示不自动跑）。
- 输出中文，段落清晰，末尾给出结论。

## 验证基准

- `bash -n` 通过。
- 桩模拟：无 smartctl 时提示安装；有 smartctl 且无错误字段→健康；命中 I/O error→异常。
- 真实环境由用户在服务器执行反馈。

## 交付位置

`offline-stress-pkg/check-nvme-health.sh`
