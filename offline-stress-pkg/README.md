# stress 离线安装与使用说明（Kylin V10 SP3）

## 1. 背景与适用环境

本包用于在**无网络**的服务器上离线安装 Linux 压测工具 `stress`（1.0.4）。

- 适用系统：Kylin V10 SP3 2403 **x86_64**
- 传输方式：通过 **U 盘**拷贝到服务器
- 参考服务器配置：Hygon 7380 双路 CPU（**64 物理核**）、**1024 GB 内存**（文中压测示例基于该配置，实际请按需调整）
- 软件包：`stress-1.0.4-24.el8.x86_64.rpm`（含 SHA256 完整性校验）

## 2. 包结构说明

```
offline-stress-pkg/
├── README.md                      本说明文档
├── install.sh                     安装脚本（含 root 检查、SHA256 校验、已装同版本检测）
├── verify.sh                      验证脚本（检查安装版本 + 10 秒冒烟压测）
├── stress-test.sh                 压测主控脚本（CPU/内存/硬盘压测：start/status/stop/review）
├── disk-mount.sh                  挂载辅助脚本（list/mount/umount，硬盘压测前挂载测试盘）
├── 压测实操手册.md                     压测操作手册（三类机型 CPU/内存/硬盘实操）
└── rpms/
    └── stress-1.0.4-24.el8.x86_64.rpm   stress RPM 安装包
```

拷贝时请**保持整个目录结构不变**，脚本会按相对路径 `rpms/` 定位 RPM 文件。

## 3. U 盘拷贝步骤

**主路径（推荐）：拷贝整个目录**

1. 在联网的机器上（或直接从资料交接处）拿到 `offline-stress-pkg` 目录；
2. 将**整个 `offline-stress-pkg` 目录**拷贝到 U 盘（保持目录层级不变）；
3. 服务器上插入 U 盘，挂载后把整个目录拷到服务器，例如：

```bash
# 以挂载点为 /mnt/usb 为例（具体路径以实际挂载为准）
mkdir -p ~/offline-stress-pkg
cp -r /mnt/usb/offline-stress-pkg/* ~/offline-stress-pkg/
cd ~/offline-stress-pkg
```

> 说明：若为了方便将包打成 zip 拷贝，服务器上**必须已安装 unzip** 才能解压；**若服务器缺 unzip，请直接使用目录拷贝方式**，不要依赖 zip。

## 4. 安装

在包目录下执行：

```bash
sudo bash install.sh
```

- 已是 root 用户时直接执行 `bash install.sh` 即可；
- **非 root 且未加 sudo 时，脚本会提示并退出**（提示：请以 root 运行：sudo bash install.sh）；
- 脚本会自动完成：root 检查 → RPM 文件存在性检查 → SHA256 完整性校验 → 已安装同版本检测（已装则提示"已安装"并退出 0）→ `rpm -Uvh` 安装；
- 安装成功输出 `stress 安装成功：stress-1.0.4-24.el8.x86_64`，退出码 0。

## 5. 验证

```bash
bash verify.sh
```

- 共 3 项检查：
  - 检查 A：`rpm -q stress` 输出精确匹配 `stress-1.0.4-24.el8.x86_64`
  - 检查 B：`stress --version` 输出包含 `1.0.4`
  - 检查 C：10 秒冒烟压测（`stress --cpu 2 --vm 1 --vm-bytes 256M --timeout 10`）
- 全部通过输出 `PASS`，退出码 0；任一项失败输出 `FAIL`，退出码 1。

**跳过冒烟压测**：若不想运行 10 秒冒烟压测（例如机器正在跑业务），可跳过：

```bash
VERIFY_SKIP_SMOKE=1 bash verify.sh
```

此时检查 C 输出 `SKIP`，A、B 通过即为 `PASS`。

压测实操见同目录 压测实操手册.md

## 6. NOKEY 签名警告说明

安装时 rpm 可能输出类似警告：

```
warning: rpms/stress-1.0.4-24.el8.x86_64.rpm: Header V4 RSA/SHA256 Signature, key ID xxx: NOKEY
```

原因：rpm 校验签名需要对应的 EPEL GPG 公钥，而离线服务器**未导入该公钥**，属正常现象，**不影响安装结果**。脚本以 rpm 退出码判定成败，出现 NOKEY 警告后安装仍会成功。

## 7. 卸载

```bash
rpm -e stress
```

卸载后可用 `rpm -q stress` 确认（输出"未安装"即卸载成功）。

## 8. 压测用法示例（参考 64 核 / 1024G 配置）

> 所有示例均带 `--timeout`，压测**到时自动结束**，避免长时间占用资源；长时间压测建议用 `nohup` 放后台运行（见下文）。参数请按实际压测需求调整。

**纯 CPU 压测**（占用全部 64 物理核，每个核一个 worker）：

```bash
stress --cpu 64 --timeout 600
```

**内存压测**（16 个 worker 各申请 8G，共约 128G，注意观察内存占用）：

```bash
stress --vm 16 --vm-bytes 8G --timeout 600
```

**组合压测**（CPU + 内存同时压，共 64 worker）：

```bash
stress --cpu 64 --vm 16 --vm-bytes 8G --timeout 600
```

**后台运行 + 日志**（长时间压测，如 1 小时，放后台并记录日志）：

```bash
nohup stress --cpu 64 --vm 16 --vm-bytes 8G --timeout 3600 > stress.log 2>&1 &
```

- 查看日志：`tail -f stress.log`；结束后用 `jobs` / `ps -ef | grep stress` 确认进程已退出；
- 其它常用选项：`--hdd`（写磁盘）、`--io`（I/O 压测）、`-q`（静默输出）等，详见 `stress --help`；
- **注意事项**：`--vm-bytes` 总量不宜超过实际可用内存（本机 1024G，示例共 128G 属安全范围）；压测会显著增加 CPU 温度与功耗，请确认散热与机房环境。

## 9. 故障回退（依赖缺失时）

以下命令需 root 权限执行。

若 `rpm -Uvh` 因依赖缺失失败（如缺 `libc` 相关依赖版本不符），可将 **Kylin V10 SP3 系统 ISO** 挂载为本地 yum 源后重试：

```bash
# 挂载 ISO（以 /dev/cdrom 为例，ISO 文件时用 mount -o loop）
mkdir -p /mnt/iso
mount -o loop /path/to/Kylin-V10-SP3.iso /mnt/iso

# 配置本地源
cat > /etc/yum.repos.d/kylin-local.repo <<'EOF'
[kylin-local]
name=Kylin Local ISO
baseurl=file:///mnt/iso
enabled=1
gpgcheck=0
EOF

# 重试安装（自动解析本地依赖）
yum localinstall rpms/*.rpm -y
```

> 安装成功后无需保留本地源，可卸载 ISO：`umount /mnt/iso`，并删除 `/etc/yum.repos.d/kylin-local.repo`。

---

若仍有问题，将 `install.sh` / `verify.sh` 的输出连同执行命令一并反馈。
