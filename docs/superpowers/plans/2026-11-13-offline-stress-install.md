# 离线安装 stress 压测工具 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在本机（Windows 工作站，可联网）制作一个自包含的离线安装包 `offline-stress-pkg/`（含 stress RPM、安装脚本、验证脚本、README），供用户 U 盘拷贝到无网的 Kylin V10 SP3 服务器上离线安装并验证 stress 可用。

**Architecture:** 交付物为目录形态（zip 仅作便捷副本）。RPM 已从 aliyun EPEL 8 镜像下载并锁定 SHA256（零额外依赖，单包 `rpm -Uvh` 直装）。服务器侧执行 `install.sh`（root 检查 → SHA256 校验 → 安装）与 `verify.sh`（版本 + 冒烟压测），全部离线完成。

**Tech Stack:** RPM（el8 x86_64）、bash 脚本（服务器侧）、PowerShell/Windows + WSL bash（本机侧质检）、git。

**Spec:** [2026-11-13-offline-stress-install-design.md](file:///c:/Users/ganxin01/Documents/trae-work/ServerSystemTest/docs/superpowers/specs/2026-11-13-offline-stress-install-design.md)

## Global Constraints

- 交付物根目录：`c:\Users\ganxin01\Documents\trae-work\ServerSystemTest\offline-stress-pkg\`（zip 副本为同级 `offline-stress-pkg.zip`）
- RPM 文件：`stress-1.0.4-24.el8.x86_64.rpm`；**SHA256 锁定值：`0090571FD05C307DBE894E0FCF1E9804DBB27EA64D11A6D0248FFA61AE93EFDA`**
- 下载源：https://mirrors.aliyun.com/epel/8/Everything/x86_64/Packages/s/stress-1.0.4-24.el8.x86_64.rpm
- 安装命令：`rpm -Uvh`（升级式，兼容全新安装与旧版覆盖）
- 服务器侧脚本为 bash；服务器有 root/可 sudo、允许短时小负载；冒烟压测参数固定 `--cpu 2 --vm 1 --vm-bytes 256M --timeout 10`
- 验收：服务器上 `bash install.sh` 后 `bash verify.sh` 全部检查 PASS 且退出码 0
- 提交消息遵循全局格式：`type(scope): 一句话`，body 含原因/改动/影响要点
- 本机 WSL bash 路径映射：`c:\Users\...` ↔ `/mnt/c/Users/...`

## Review Focus

1. **RPM 拷贝损坏（U 盘常见）** → 安装前 SHA256 校验必须失败并中止，绝不带病安装 → 测试：Task 2 损坏副本场景。
2. **非 root 运行安装脚本** → 必须明确提示 `sudo bash install.sh` 并以非零码退出（在触碰 rpm 之前）→ 测试：Task 2 非 root 场景（WSL 天然非 root）。
3. **服务器已装过旧版 stress** → `rpm -Uvh` 应升级而非报错；若已装同版本 → 打印"已安装"并成功退出 → Task 2 内建 + 服务器侧验收。
4. **服务器缺 unzip** → 目录形态即可用，zip 只是副本 → Task 5 打包 + Task 4 README 说明主路径用目录。
5. **生产环境不希望跑任何负载** → `VERIFY_SKIP_SMOKE=1` 跳过冒烟压测，其余检查照跑 → Task 3 实现并在 Task 4 README 说明。

---

### Task 1: 建立交付目录并锁定 RPM

**Files:**
- Create: `offline-stress-pkg/rpms/stress-1.0.4-24.el8.x86_64.rpm`（自 `%TEMP%\trae-stress-recon\stress.rpm` 拷贝）

**Interfaces:**
- Consumes: 已下载并 SHA256 复核过的 RPM（临时目录中现成的 `stress.rpm`）
- Produces: 交付目录结构骨架 `offline-stress-pkg/rpms/` + 经锁定的 RPM 文件（后续 2-4 任务向该目录写入文件）

- [ ] **Step 1: 建目录并拷贝 RPM**

```powershell
New-Item -ItemType Directory -Force -Path "c:\Users\ganxin01\Documents\trae-work\ServerSystemTest\offline-stress-pkg\rpms" | Out-Null
Copy-Item "$env:TEMP\trae-stress-recon\stress.rpm" "c:\Users\ganxin01\Documents\trae-work\ServerSystemTest\offline-stress-pkg\rpms\stress-1.0.4-24.el8.x86_64.rpm"
```

- [ ] **Step 2: 校验 SHA256 与锁定值一致**

```powershell
(Get-FileHash "...\stress-1.0.4-24.el8.x86_64.rpm" -Algorithm SHA256).Hash
```

Expected: `0090571FD05C307DBE894E0FCF1E9804DBB27EA64D11A6D0248FFA61AE93EFDA`（大小 39,864 字节）

- [ ] **Step 3: Commit**

```bash
git add offline-stress-pkg/rpms/stress-1.0.4-24.el8.x86_64.rpm
git commit -m "feat(offline-stress): 锁定 stress RPM 到交付目录"
```

---

### Task 2: 编写 install.sh（安装脚本）

**Files:**
- Create: `offline-stress-pkg/install.sh`

**Interfaces:**
- Consumes: Task 1 的 `rpms/stress-1.0.4-24.el8.x86_64.rpm`
- Produces: 脚本契约——退出码 `0`=成功（含已装同版本）；`1`=失败（非 root / 校验失败 / 安装失败）。环境变量接缝 `INSTALL_SKIP_ROOT_CHECK=1`（仅测试用，跳过 root 检查以允许在 WSL 本地测校验路径）。脚本自动定位自身目录（`cd "$(dirname "$0")"`）保证任意位置调用。

- [ ] **Step 1: 编写 install.sh**

行为（按此顺序，全部离线）：
1. 解析自身目录并 cd 过去（`SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)`）
2. root 检查：`[ "$(id -u)" -eq 0 ]` 失败且 `INSTALL_SKIP_ROOT_CHECK != 1` → 输出 `请以 root 运行：sudo bash install.sh`，退出 1
3. 文件存在检查：`rpms/stress-1.0.4-24.el8.x86_64.rpm` 缺失 → 退出 1
4. SHA256 校验：`echo "<锁定值>  rpms/stress-1.0.4-24.el8.x86_64.rpm" | sha256sum -c -` 失败 → 输出"RPM 校验失败，文件可能损坏，请重新拷贝"，退出 1
5. 已安装检查：`rpm -q stress` 成功且版本含 `1.0.4-24.el8` → 输出"已安装"，退出 0
6. 安装：`rpm -Uvh rpms/stress-1.0.4-24.el8.x86_64.rpm`，用退出码判断成败（NOKEY 警告属正常，README 说明）；成功输出版本号与"下一步运行 bash verify.sh"
7. 全程不启用 `set -e`（需自行判断 rpm 退出码）；输出中英文均可，但提示语保持中文

- [ ] **Step 2: 语法检查**

Run (WSL): `bash -n /mnt/c/Users/ganxin01/Documents/trae-work/ServerSystemTest/offline-stress-pkg/install.sh`
Expected: 无输出，退出码 0

- [ ] **Step 3: 非 root 场景测试（WSL 天然非 root）**

Run (WSL, 从交付目录): `cd /mnt/c/Users/ganxin01/Documents/trae-work/ServerSystemTest/offline-stress-pkg && bash install.sh`
Expected: 输出含 `sudo bash install.sh`，退出码 1，且**未执行任何 rpm 命令**

- [ ] **Step 4: 校验失败场景测试（损坏副本）**

```bash
cd /mnt/c/Users/ganxin01/Documents/trae-work/ServerSystemTest/offline-stress-pkg
cp rpms/stress-1.0.4-24.el8.x86_64.rpm /tmp/stress-copy.rpm   # 备份
printf 'corrupted' >> rpms/stress-1.0.4-24.el8.x86_64.rpm     # 破坏文件
INSTALL_SKIP_ROOT_CHECK=1 bash install.sh                      # 期望: 输出"校验失败"，退出 1
cp /tmp/stress-copy.rpm rpms/stress-1.0.4-24.el8.x86_64.rpm    # 还原
```
Expected: 输出含"校验失败"，退出码 1；还原后 `sha256sum -c` 恢复通过

- [ ] **Step 5: 还原确认**

Run: `echo "<锁定值>  rpms/stress-1.0.4-24.el8.x86_64.rpm" | sha256sum -c -`
Expected: `OK`

- [ ] **Step 6: Commit**

```bash
git add offline-stress-pkg/install.sh
git commit -m "feat(offline-stress): 新增离线安装脚本 install.sh

- 原因：服务器无网，需离线安装 stress
- 改动：root 检查/SHA256 完整性校验/rpm -Uvh，已装同版本提前退出
- 影响：本地 3 项场景测试通过；真实安装留待服务器侧验收"
```

---

### Task 3: 编写 verify.sh（验证脚本）

**Files:**
- Create: `offline-stress-pkg/verify.sh`

**Interfaces:**
- Consumes: Task 2 安装完成的 `stress` 命令
- Produces: 脚本契约——逐项输出 `PASS`/`FAIL`，最终 `PASS`/`FAIL`，退出码 0/1。环境变量 `VERIFY_SKIP_SMOKE=1` 跳过冒烟压测。

- [ ] **Step 1: 编写 verify.sh**

行为：
1. 检查 A：`rpm -q stress` 输出精确为 `stress-1.0.4-24.el8.x86_64` → PASS 否则 FAIL（并提示先运行 install.sh）
2. 检查 B：`stress --version` 输出包含 `1.0.4` → PASS 否则 FAIL
3. 检查 C（冒烟，`VERIFY_SKIP_SMOKE != 1` 时执行）：`stress --cpu 2 --vm 1 --vm-bytes 256M --timeout 10` 退出码 0 → PASS；被跳过时输出 `SKIP`
4. 汇总：三项全 PASS → `PASS` 退出 0；任一 FAIL → `FAIL` 退出 1

- [ ] **Step 2: 语法检查**

Run (WSL): `bash -n /mnt/c/Users/ganxin01/Documents/trae-work/ServerSystemTest/offline-stress-pkg/verify.sh`
Expected: 无输出，退出码 0

- [ ] **Step 3: 本机（WSL，无 rpm/stress）运行——验证 FAIL 分支正确**

Run: `cd /mnt/c/Users/ganxin01/Documents/trae-work/ServerSystemTest/offline-stress-pkg && bash verify.sh`
Expected: 检查 A/B 输出 `FAIL`，最终 `FAIL`，退出码 1（证明错误分支与退出码逻辑正确；PASS 路径留服务器侧验收）

- [ ] **Step 4: Commit**

```bash
git add offline-stress-pkg/verify.sh
git commit -m "feat(offline-stress): 新增验证脚本 verify.sh"
```

---

### Task 4: 编写 README.md（使用说明）

**Files:**
- Create: `offline-stress-pkg/README.md`

**Interfaces:**
- Consumes: Task 1-3 产物（目录结构、脚本用法）
- Produces: 用户在服务器上的操作手册

- [ ] **Step 1: 编写 README.md**

内容清单（与 spec 逐条对应，缺一条即不通过）：
1. 背景与适用环境（Kylin V10 SP3 x86_64、无网、U 盘）
2. 包结构说明（rpms/、install.sh、verify.sh、README.md）
3. U 盘拷贝步骤（**主路径：拷贝整个目录；zip 仅当方便时用，服务器缺 unzip 就直接用目录**）
4. 安装：`sudo bash install.sh`（或 root 下 `bash install.sh`）；说明非 root 时脚本会提示
5. 验证：`bash verify.sh`；说明 `VERIFY_SKIP_SMOKE=1 bash verify.sh` 可跳过 10 秒冒烟压测
6. NOKEY 签名警告说明（未导入 EPEL GPG 公钥所致，属正常，不影响安装）
7. 卸载：`rpm -e stress`
8. 压测用法示例（参考本服务器 64 核/1024G 配置）：如 `stress --cpu 64 --timeout 600`（纯 CPU）、`stress --vm 16 --vm-bytes 8G --timeout 600`（内存）、组合用法与 `timeout`/后台运行说明；注明压测参数需按实际需求调整
9. 故障回退：万一出现依赖缺失，挂载 Kylin ISO 为本地 yum 源后 `yum localinstall rpms/*.rpm`

- [ ] **Step 2: 按清单自查**

逐项核对上面 9 条是否都出现在 README 中（自检清单勾选）。

- [ ] **Step 3: Commit**

```bash
git add offline-stress-pkg/README.md
git commit -m "docs(offline-stress): 新增离线安装使用说明 README"
```

---

### Task 5: 整包质检 + zip 打包

**Files:**
- Create: `offline-stress-pkg.zip`（与交付目录同级）
- 质检对象：`offline-stress-pkg/` 全部内容

**Interfaces:**
- Consumes: Task 1-4 全部产物
- Produces: 最终交付物（目录 + zip）

- [ ] **Step 1: 结构清单核对**

Expected（缺一不可）：
```
offline-stress-pkg/
├── rpms/stress-1.0.4-24.el8.x86_64.rpm
├── install.sh
├── verify.sh
└── README.md
```

- [ ] **Step 2: 全脚本语法复检**

Run (WSL): `bash -n .../install.sh && bash -n .../verify.sh`
Expected: 均无输出、退出码 0

- [ ] **Step 3: RPM SHA256 复检**

Run: `(Get-FileHash "...\stress-1.0.4-24.el8.x86_64.rpm" -Algorithm SHA256).Hash`
Expected: 与锁定值一致

- [ ] **Step 4: 打包 zip**

```powershell
Compress-Archive -Path "c:\Users\ganxin01\Documents\trae-work\ServerSystemTest\offline-stress-pkg" -DestinationPath "c:\Users\ganxin01\Documents\trae-work\ServerSystemTest\offline-stress-pkg.zip" -Force
```

- [ ] **Step 5: zip 完整性抽查**

```powershell
Expand-Archive -Path "...\offline-stress-pkg.zip" -DestinationPath "$env:TEMP\trae-stress-recon\zip-check" -Force
# 逐一比较 zip 解出的 4 个文件 SHA256 与原目录一致
```
Expected: 4 个文件哈希全部一致

- [ ] **Step 6: Commit**

```bash
git add offline-stress-pkg.zip
git commit -m "chore(offline-stress): 打包并质检离线安装包"
```

---

### 终检（整支复查）

按 superpowers:subagent-driven-development 流程，全部任务完成后由**新的 reviewer subagent** 对整支交付做复查：结构完整性、脚本逻辑与 spec 一致性、锁定哈希、zip 可解压。复查通过即交付。
