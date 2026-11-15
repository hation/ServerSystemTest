# 2026-11-13 离线安装 stress 压测工具 — 设计文档

## 背景与意图（Why）

H3C UniServer R4930 G5 服务器（Kylin V10 SP3 2403 Release，x86_64，海光 7380 双 CPU / 1024GB 内存）需要进行压力测试，但服务器**无法联网**，无法直接执行 `yum install -y stress` 从在线仓库安装。

本机（Windows 工作站）可访问外网。方案为：**在本机下载兼容 Kylin V10 SP3 的 stress RPM 包，制作自包含的离线安装包，经 U 盘拷贝到服务器后离线安装**，达到"装好软件、可立即开始压测"的目的。

## 目标（Goals）

- 交付一个自包含的离线安装包（目录 + 可选 zip），包含：stress RPM、安装脚本、验证脚本、中文使用说明
- 服务器上**全程无需联网**即可完成安装
- 提供一键安装（`bash install.sh`）与一键验证（`bash verify.sh`）
- 验证标准明确：版本正确 + 功能冒烟压测通过

## 非目标 / 反目标（Non-goals / Anti-goals）

- **不在本机安装任何软件**——本机只负责下载、打包、质检
- **不附带 stress-ng**——用户明确要求 `stress`；stress-ng 依赖多个附加 RPM，会破坏"单包直装"的简洁性
- **不制定压测方案**（压多少 CPU / 多少内存）——本次只把工具装好；压测参数示例仅供使用参考
- **不要求服务器挂载 Kylin ISO**——方案完全自包含，U 盘即插即用

## 约束（Constraints）

- 服务器无外网；传输介质为 U 盘 → 交付物应是一个可整体拷贝的目录（zip 为便捷副本）
- 服务器系统：Kylin V10 SP3 2403 x86_64，RHEL8 兼容生态（el8 RPM 可直接安装），自带 `rpm`/`bash`
- **具备 root 权限（或可 sudo）**：安装脚本按 root 前提设计
- **允许短时小负载**：验证脚本可运行 10 秒冒烟压测（用户已确认）
- 服务器默认带 SELinux（enforcing）→ 通过 `rpm -ivh` 安装，SELinux 上下文由 rpm 自动处理，无特殊要求

## 关键技术事实（已侦察确认）

| 项 | 值 |
|---|---|
| 软件包 | `stress-1.0.4-24.el8.x86_64.rpm`（EPEL 8） |
| 下载源 | https://mirrors.aliyun.com/epel/8/Everything/x86_64/Packages/s/stress-1.0.4-24.el8.x86_64.rpm |
| 大小 | 39,864 字节 |
| SHA256 | `0090571FD05C307DBE894E0FCF1E9804DBB27EA64D11A6D0248FFA61AE93EFDA` |
| 运行时依赖（EPEL repodata 权威确认） | `libc.so.6(GLIBC_2.7)(64bit)`、`libm.so.6()(64bit)`、`libm.so.6(GLIBC_2.2.5)(64bit)`、`rtld(GNU_HASH)` |
| 依赖结论 | 全部由系统 glibc（Kylin V10 SP3 自带 glibc 2.28）提供 → **零额外依赖，单 RPM 可离线直装** |
| 安装产物 | `/usr/bin/stress` |
| 版本/许可 | 1.0.4，GPLv2 |

## 方案设计（How，已定）

### 交付物结构（规范形态为目录，可整体拷贝到 U 盘）

```
offline-stress-pkg/
├── rpms/
│   └── stress-1.0.4-24.el8.x86_64.rpm
├── install.sh          # 一键安装：root 检查 → SHA256 完整性校验 → rpm -ivh
├── verify.sh           # 一键验证：rpm -q / stress --version / 10 秒冒烟压测
└── README.md           # 中文使用说明：拷贝、安装、验证、卸载、压测用法示例
```

另打包 `offline-stress-pkg.zip` 作为 U 盘便捷副本（服务器上如缺 `unzip`，直接用解压后的目录即可）。

### 服务器端安装方式

- 主路径：`bash install.sh` → 内部执行 `rpm -Uvh rpms/stress-1.0.4-24.el8.x86_64.rpm`
  - 使用 `-Uvh`（升级式安装）：对全新安装与"服务器已有旧版 stress"两种情况均安全（覆盖旧版本，避免 `-ivh` 在已安装时报错）
  - 安装前先校验 RPM 的 SHA256 与包内清单一致（防 U 盘拷贝损坏）
  - `NOKEY` 签名提示属正常现象（未导入 EPEL GPG 公钥），不影响安装，README 中说明
  - 脚本需 root 执行；如以普通用户运行且可 sudo，脚本内自动检测并提示用 `sudo bash install.sh`
- 回退路径（README 中说明，概率极低）：若意外出现依赖缺失，可挂载 Kylin ISO 为本地 yum 源后执行 `yum localinstall`

### 验证（验收标准）

- 服务器侧验收：`bash verify.sh` 全部通过，输出 `PASS`
  1. `rpm -q stress` 返回 `stress-1.0.4-24.el8.x86_64`
  2. `stress --version` 返回 `1.0.4`
  3. 冒烟压测（用户已确认允许）：`stress --cpu 2 --vm 1 --vm-bytes 256M --timeout 10` 退出码 0；提供 `VERIFY_SKIP_SMOKE=1` 环境变量跳过开关以备不时之需
- 本机侧质检（实现阶段完成）：RPM 下载 + SHA256 与 EPEL repodata 的 pkgId 一致（已确认）；脚本 `bash -n` 语法检查；zip 结构完整性检查

## 设计决策记录（我的决定，可推翻）

1. **仅安装 stress，不附带 stress-ng**：严格符合用户要求（`yum install -y stress`）；保持单包直装。若后续需要更细粒度压测，再单独评估 stress-ng 的依赖打包。
2. **安装命令用 `rpm -Uvh` 而非 `-ivh`**：覆盖"服务器可能已装旧版 stress"的情况（builder-check 提出的问题 1，我的定案）；全新安装同样适用。
3. **包内做 SHA256 完整性校验**：U 盘拷贝易损坏，校验成本极低，收益明确。
4. **交付物以目录为规范形态，zip 为副本**：避免服务器上缺 `unzip` 的麻烦。
5. **验证脚本含 10 秒冒烟压测**：用户已确认允许短时小负载；10 秒、2 核 + 256MB，对 64 核/1024G 机器无感，能真实证明工具可用。另留 `VERIFY_SKIP_SMOKE=1` 跳过开关。
6. **root 前提**：用户确认有 root/可 sudo，脚本按 root 设计并给出 sudo 提示。

## 留给实现者的部分

- 三个脚本的具体实现细节（错误处理、输出风格）
- README 的具体措辞与压测命令示例（可参考服务器配置给出：64 核、1024G、`stress --cpu 64 ...` 等）
- 本地质检步骤的落地方式
