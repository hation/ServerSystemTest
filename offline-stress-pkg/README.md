# stress 离线安装与使用说明（Kylin V10 SP3）

## 1. 背景与适用环境

本包用于在**无网络**的服务器上离线安装 Linux 压测工具 `stress`（1.0.4）。

- 适用系统：Kylin V10 SP3 2403 **x86_64**
- 传输方式：通过 **U 盘**拷贝到服务器
- 参考服务器配置：Hygon 7380 双路 CPU（**64 物理核**）、**1024 GB 内存**（仅第 8 节的手工 `stress` 示例基于该配置；`stress-test.sh` 的正式压测参数按本机实测推导）
- 软件包：`stress-1.0.4-24.el8.x86_64.rpm`、`dmidecode-3.2-10.el8.x86_64.rpm`（含 SHA256 完整性校验；dmidecode 用于自动探测内存条根数）

## 2. 包结构说明

```
offline-stress-pkg/
├── README.md                      本说明文档
├── install.sh                     安装脚本（含 root 检查、SHA256 校验、已装同版本检测）
├── verify.sh                      验证脚本（检查安装版本 + 10 秒冒烟压测 + dmidecode 可用性）
├── stress-test.sh                 压测主控脚本（CPU/内存/硬盘压测：start/status/stop/review）
├── oneclick.sh                    一键压测入口（菜单/子命令：自动挂载+分窗+自动复盘）
├── disk-mount.sh                  挂载辅助脚本（list/mount/umount，硬盘压测前挂载测试盘）
├── mount-iso.sh                   U盘+yum源脚本（build/mount/status/umount，构建源并配置本地源）
├── usb-eject.sh                   U盘安全弹出脚本（自动识别并卸载全部挂载点，--poweroff 可断电）
├── usb-mount-guide.md             U盘挂载操作说明（未挂载时先看这个，纯命令可直接复制）
├── operation-manual.md                 压测操作手册（三类机型 CPU/内存/硬盘实操）
└── rpms/
    ├── stress-1.0.4-24.el8.x86_64.rpm      stress RPM 安装包
    └── dmidecode-3.2-10.el8.x86_64.rpm     dmidecode RPM（自动探测内存条根数）
```

拷贝时请**保持整个目录结构不变**，脚本会按相对路径 `rpms/` 定位 RPM 文件。

> `oneclick.sh` 每次运行会在批次目录 `/root/stress-test/oneclick-<时间>/` 下**自动生成**三个记录文件（命令清单 + 重放脚本 + 环境快照）（不属于离线包内容，随每次执行重建）：
>
> | 文件 | 用途 |
> |---|---|
> | `commands.txt` | 本次实际执行过的命令逐条记录（可直接复制重跑；复盘命令自动去重） |
> | `commands.sh` | 可重放的启动脚本（含 shebang、批次路径、重放警告；只含挂载与各任务启动命令，不含复盘；权限 0644；**执行它会重新发起一轮压测**） |
> | `env.txt` | 本次执行环境快照（`BATCH`/`MODE`/`START_TIME`/`TIMEOUT`/`STRESS_TEST_ROOT`/`STRESS_TEST_SH`/`DISK_MOUNT_SH`/`TERM_KIND`/`POLL_INTERVAL`/`READY_TIMEOUT`/`SHOW_CMD`） |

## 3. U 盘拷贝步骤

> **U 盘还没挂载？** 先按 [usb-mount-guide.md](usb-mount-guide.md) 复制命令完成挂载（纯手工命令，不依赖包内脚本），再回来做拷贝。

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
- 脚本会自动完成：root 检查 → RPM 文件存在性检查 → SHA256 完整性校验 → 已安装同版本检测（已装则提示"已安装"并跳过）→ 逐个 `rpm -Uvh` 安装 `stress` 与 `dmidecode`；
- 安装成功输出 `stress 安装成功：stress-1.0.4-24.el8.x86_64` 与 `dmidecode 安装成功：dmidecode-3.2-10.el8.x86_64`，退出码 0。
- 若目标机不允许安装 dmidecode，`stress-test.sh` 仍可通过 EDAC 或手动 `--vm` 完成内存压测（见操作手册边界说明）。

### 4.1 一键压测（推荐）

装完 `stress` 后，用 `oneclick.sh` 一条命令跑完整个流程：

```bash
sudo bash oneclick.sh                # 菜单：1 全测 / 2 只测硬盘 / 3 只测系统盘 / 4 只测 CPU / 5 只测内存 / 6 查看状态 / 7 生成复盘
sudo bash oneclick.sh all --timeout 10h
sudo bash oneclick.sh hdd --timeout 8h
```

要点：

- **全测顺序**：自动挂载（`disk-mount.sh mount --disks all --yes`）→ 每块数据盘 → 系统盘 → CPU → 内存；
- **每块数据盘一个窗口**，窗口标题为 `压测-HDDxx`（另有 `压测-系统盘` / `压测-CPU` / `压测-内存`）；无图形环境（SSH、无 `DISPLAY`）自动降级为后台并行执行；
- **失败即停**：启动阶段任一任务失败，立即停止启动后续任务并打印已启动清单与失败原因；
- **自动复盘**：全部结束后自动逐个 `review` 并生成汇总 `summary.txt`，位置为 `/root/stress-test/oneclick-<时间>/summary.txt`（存在异常结论时退出码 1）；
- **命令可见性**：每个任务启动前主终端打印 `[<时间>] 任务 HDD01 将执行：` 与其后的 `  $ bash <包绝对路径>/stress-test.sh start hdd --timeout 10h --dirs /mnt/HDD01`；自动挂载前打印 `  $ bash <包绝对路径>/disk-mount.sh mount --disks all --yes`；复盘前打印 `  $ bash <包绝对路径>/stress-test.sh review --dir <结果目录>`。窗口内首屏也有同样的启动命令 banner（`==== HDD01 启动命令 ====` / `  $ …` / `======================`）；
- **命令落盘**：上述命令写入批次目录的 `commands.txt`（逐条可复制）与 `commands.sh`（可重放启动）；同目录另生成 `env.txt`（环境快照），用途见第 2 节；启动失败时始终单独打印“该任务压测命令（可直接复制重跑）：”；
- **`--quiet` 静默**：`sudo bash oneclick.sh all --quiet`（或 `ONECLICK_SHOW_CMD=0 sudo -E bash oneclick.sh all`）关闭终端命令打印，三个命令文件照常生成；
- 其它子命令：`sudo bash oneclick.sh status` 查看最近批次状态（有批次且存在 `commands.txt` 时会额外提示 `查看本次执行过的命令：cat <批次>/commands.txt`），`sudo bash oneclick.sh review` 重新生成复盘。

## 5. 验证

```bash
bash verify.sh
```

- 共 4 项检查：
  - 检查 A：`rpm -q stress` 输出精确匹配 `stress-1.0.4-24.el8.x86_64`
  - 检查 B：`stress --version` 输出包含 `1.0.4`
  - 检查 C：10 秒冒烟压测（`stress --cpu 2 --vm 1 --vm-bytes 256M --timeout 10`）
  - 检查 D：`dmidecode` 是否可用（缺失只输出 `WARN`，不影响 PASS/退出码）
- 全部通过输出 `PASS`，退出码 0；任一 `FAIL` 输出 `FAIL`，退出码 1。

**跳过冒烟压测**：若不想运行 10 秒冒烟压测（例如机器正在跑业务），可跳过：

```bash
VERIFY_SKIP_SMOKE=1 bash verify.sh
```

此时检查 C 输出 `SKIP`，A、B 通过即为 `PASS`。

压测实操见同目录 operation-manual.md

## 6. NOKEY 签名警告说明

安装时 rpm 可能输出类似警告：

```
warning: rpms/stress-1.0.4-24.el8.x86_64.rpm: Header V4 RSA/SHA256 Signature, key ID xxx: NOKEY
```

原因：rpm 校验签名需要对应的 EPEL GPG 公钥，而离线服务器**未导入该公钥**，属正常现象，**不影响安装结果**。脚本以 rpm 退出码判定成败，出现 NOKEY 警告后安装仍会成功。

## 7. 卸载

```bash
rpm -e stress
rpm -e dmidecode   # 可选：仅在不需要自动探测内存条根数时卸载
```

卸载后可用 `rpm -q stress` 确认（输出"未安装"即卸载成功）。

## 8. 压测用法示例

正式压测请直接用包内 `stress-test.sh`：CPU/内存参数由脚本按**本机实测规格**推导（CPU `floor(nproc × 86%)`、内存 `MemTotal × 82%`、`--vm` = 实际内存条根数），**默认命令不需要 `--model`**：

```bash
bash stress-test.sh start cpu
bash stress-test.sh start mem
bash stress-test.sh start combo
```

`--model 5380|7380|7360|auto` 仅用于 `run-config.txt` / `review` 的机型标注与"实测线程 vs 标称线程"交叉校验，**不影响任何压测参数**（默认 `auto` 已够用）。

以下为直接调用 `stress` 的手工示例（参考 64 核 / 1024G 配置），仅用于了解原始工具用法：

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

## 10. U 盘与本地 yum 源一键管理（mount-iso.sh）

`mount-iso.sh` 提供四个子命令，打通"构建源 → 写入 U 盘 → 挂载复制 → 配置本地源"：

```bash
# 进入离线包目录（按实际位置调整）
cd /root/offline-stress-pkg

# 1) 构建 yum 源（createrepo 生成 repodata，需 root）
#    RPM 来源优先级：U盘内（已挂载且含 *.rpm） > --rpm-dir > 包内 rpms/
sudo bash mount-iso.sh build
sudo bash mount-iso.sh build --rpm-dir /root/my-rpms    # ← 换成你实际的 RPM 目录

# 2) 一键：U盘挂载 → 复制源目录到 /opt/kylin-repo → 配置本地 yum 源
sudo bash mount-iso.sh mount

# 3) 查看状态
bash mount-iso.sh status

# 4) 卸载 U 盘（不影响已复制的本地源）
sudo bash mount-iso.sh umount
```

> 注意：脚本必须在包目录内执行（或写脚本绝对路径）；`build`/`mount`/`umount` 需 root（用 `sudo`），`status` 无需。`--rpm-dir` 后是**实际目录**，不能照抄 `/path/to/rpms`。

要点：

- **build**：用 `createrepo --update` 在 RPM 目录生成 `repodata/`；构建结果复制到 `/opt/kylin-repo`，U 盘已挂载时另写一份 `<U盘>/kylin-repo` 方便拷贝到其他机器。U 盘内 RPM 识别范围为 `maxdepth 2`，优先 `<U盘>/rpms` 子目录，仅以实际含 `*.rpm` 的目录作为源（避免把整盘复制进去）。需系统已装 `createrepo`（或 `createrepo_c`），缺失时脚本提示安装命令。
- **mount**：自动检测首块 USB 盘（`TRAN=usb`，系统盘硬排除）→ 挂载到 `/mnt/usb` → 在 U 盘内查找含 `repodata` 的目录 → 复制到 `/opt/kylin-repo` → 写 `/etc/yum.repos.d/kylin-local.repo`（`baseurl=file:///opt/kylin-repo`）。**repo 文件已存在时不覆盖（会提示实际 baseurl）**。**U 盘可拔，源仍可用**。
- **umount**：仅卸载 U 盘，不删 `/opt/kylin-repo` 与 repo 文件；如需清理请手动 `rm -rf /opt/kylin-repo` 与 `rm -f /etc/yum.repos.d/kylin-local.repo`。
- **演练**：加 `DRY_RUN=1` 只打印执行计划不落盘（如 `DRY_RUN=1 bash mount-iso.sh mount`）。
- 可覆盖路径：`USB_MOUNT_POINT`（默认 /mnt/usb）、`REPO_DEST`（默认 /opt/kylin-repo）、`YUM_REPO_FILE`（默认 /etc/yum.repos.d/kylin-local.repo）。
- **安全弹出**：`sudo bash usb-eject.sh` 自动识别 U 盘并卸载其全部挂载点（含 `/run/media` 自动挂载），加 `--poweroff` 可断电。

---

若仍有问题，将 `install.sh` / `verify.sh` 的输出连同执行命令一并反馈。
