# 计划：离线包加入 nvme-cli（兼容 Kylin V10 SP3 / el8）

- 日期：2026-11-23
- 版本：v1
- 状态：待执行

## 背景

`check-nvme-health.sh` 依赖 nvme-cli（nvme smart-log / nvme list），服务器无网络、无 nvme-cli 离线包。用户要求按项目离线包规则把兼容的 nvme-cli 打进去，离线安装验证。

## 已确认的事实

- 兼容源：CentOS 8.5 BaseOS（el8，Kylin V10 SP3 兼容）`nvme-cli-1.14-3.el8.x86_64.rpm`
- 已下载到 `offline-stress-pkg/rpms/nvme-cli-1.14-3.el8.x86_64.rpm`（474,352 字节）
- SHA256：`691F4B28D1E1668CABD38A01952F6E877FBFE0D53491E49790808C8878703FA0`（与 repodata 校验一致）
- 依赖：仅系统基础库（libc.so.6(GLIBC_2.17)/libgcc_s/libuuid/util-linux，Kylin 自带），**无需 libnvme**（nvme-cli 1.14 未拆分 libnvme 依赖）

## 改动清单

### Task 1：install.sh 增加 nvme-cli 到 RPM_LIST

在 `RPM_LIST=(...)` 数组追加一条（格式 `rpm路径|锁定SHA256|包名|已安装判定串`）：

```
"rpms/nvme-cli-1.14-3.el8.x86_64.rpm|691F4B28D1E1668CABD38A01952F6E877FBFE0D53491E49790808C8878703FA0|nvme-cli|nvme-cli"
```

同步文件头注释（"stress + dmidecode" → "stress + dmidecode + nvme-cli"）。

### Task 2：verify.sh 增加 nvme-cli 可用性检查（可选，WARN 级别，与检查 D 同风格）

在检查 D 之后加检查 E：`command -v nvme-cli` 存在→PASS，缺失→WARN（提示 install.sh 已含 nvme-cli）。

### Task 3：文档同步

- README.md：依赖清单/离线安装说明补 nvme-cli
- operation-manual.md：如提及依赖则同步
- docs/命令执行逻辑.md：如提及则同步（行号校正）

## 验证

1. `bash -n` install.sh / verify.sh。
2. RPM_LIST 格式与既有条目一致（4 字段 `|` 分隔）。
3. SHA256 匹配（`sha256sum` 或 Get-FileHash）。
4. 桩模拟：install.sh 输出包含 nvme-cli 安装行；verify.sh 检查 E 输出 PASS/WARN 正确。

## 约束

- 不 git commit/add/stash。
- 不改既有 RPM_LIST 条目；只追加。
- 不重新打包 zip（用户未要求；如需重打另行通知）。
