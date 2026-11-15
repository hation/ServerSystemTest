# U盘挂载 + yum 源构建/复制/配置 一键脚本设计（mount-iso.sh）

- 日期：2026-11-14
- 状态：待评审
- 关联脚本：`offline-stress-pkg/mount-iso.sh`（新增，四子命令：build / mount / status / umount）
- 需求来源：用户需要一套在无外网 Kylin 服务器上管理本地 yum 源的脚本，全链路：
  1. **build**：把 RPM 包目录用 `createrepo` 构建为含 `repodata/` 的完整 yum 源目录（RPM 来源：U 盘内有则用 U 盘，否则用项目包内 `rpms/`），构建结果也写入 U 盘一份，方便拷贝
  2. **mount**：U 盘挂载 → 复制 U 盘内的源目录到系统 `/opt/kylin-repo` → 配置本地 yum 源指向它（U 盘可拔，源仍可用）
  3. **status / umount**：查看状态、卸载 U 盘（不影响已复制的本地源）

## 1. 现状与目标

**现状**（手动步骤，散落在 README 第 9 节）：手动 mount、手动 createrepo、手动 cp、手动写 repo 文件。

**目标**：一个脚本四个子命令，打通"构建 → 拷入 U 盘 → 挂载复制 → 配置本地源"完整链路。

## 2. 需求确认（已与用户对齐）

- 脚本放入 `offline-stress-pkg` 包内，随包交付
- **build 子命令**：createrepo 构建 repodata（RPM 包优先级：U 盘内有 RPM 包目录 → 用 U 盘的；否则用项目包 `rpms/`）
- **mount 子命令**：U 盘挂载 → 复制源目录到 `/opt/kylin-repo`（环境变量 `REPO_DEST` 可覆盖）→ 本地 yum 源指向它
- **status / umount**：查看与卸载
- U 盘盘符：自动检测（lsblk 找 USB 设备），无需手动指定
- 不需要 ISO 挂载

## 3. 方案设计

### 3.1 用法

```
bash mount-iso.sh build [--rpm-dir /path/to/rpms]   # 构建 yum 源（createrepo）；RPM来源优先级：U盘内 > --rpm-dir > 包内 rpms/
bash mount-iso.sh mount                              # 一键：U盘挂载 → 复制源目录到 /opt/kylin-repo → 配置本地yum源
bash mount-iso.sh status                             # 查看挂载与本地源状态
bash mount-iso.sh umount                             # 卸载U盘（确认后执行；不影响已复制的本地源）

测试接缝（环境变量）:
  DRY_RUN=1           只打印计划不执行
  SKIP_ROOT_CHECK=1   跳过 root 检查（本地测试用）
  LSBLK_BIN           块设备查询命令（默认 lsblk，测试可伪造输出）
  MOUNT_LOG           操作日志路径（默认 /root/stress-test/mount.log）
  USB_MOUNT_POINT     U盘挂载点（默认 /mnt/usb）
  REPO_DEST           源目录复制/构建目标（默认 /opt/kylin-repo）
  YUM_REPO_FILE       本地源repo文件（默认 /etc/yum.repos.d/kylin-local.repo）
  PKG_RPMS_DIR        包内RPM目录（默认脚本同目录 rpms/，即 offline-stress-pkg/rpms）
  CREATEREPO_BIN      createrepo 命令（默认 createrepo，测试可伪造）
```

### 3.2 build 子命令

1. root 检查
2. **定位 RPM 包目录**（优先级从高到低）：
   - U 盘已挂载（/mnt/usb）且其中存在含 `*.rpm` 的目录 → 用 U 盘的（提示"使用 U 盘内 RPM 包"）
   - `--rpm-dir` 显式指定目录（校验含 *.rpm）
   - 否则用包内 `$PKG_RPMS_DIR`（默认 offline-stress-pkg/rpms/）
   - 三者皆无 *.rpm → 提示并退出 1
3. **createrepo 构建**：`createrepo --update <RPM目录>`（或先 `-d` 无元数据时直接 createrepo）
   - `CREATEREPO_BIN` 不存在 → 提示安装（`yum install createrepo` 或 `dnf install createrepo_c`）并退出 1
   - DRY_RUN=1 只打印命令
4. **构建结果落盘**（两处）：
   - 复制到 `$REPO_DEST`（默认 /opt/kylin-repo）：`mkdir -p` + `cp -r <RPM目录>/. $REPO_DEST/`（已存在非空 → 交互询问覆盖合并/跳过）
   - 写入 U 盘一份（U 盘已挂载时）：复制到 `$USB_MOUNT_POINT/kylin-repo/`（方便拷贝到其他机器）；U 盘未挂载 → 提示"未发现 U 盘，构建结果仅在本机 $REPO_DEST，可后续用 mount 拷贝"
5. 提示：构建完成，可用 `bash mount-iso.sh mount` 配置本地源

### 3.3 mount 子命令

1. root 检查
2. **U 盘自动检测并挂载**：
   - `lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,TRAN -l` 过滤 `TRAN=usb` 且 TYPE=disk，排除系统盘（复用 disk-mount.sh 的 `df /` 识别逻辑）
   - 取首分区（无分区则整盘）挂到 `$USB_MOUNT_POINT`（mkdir -p，已挂载跳过）；无 USB 盘 → 提示并给出手动挂载指引，退出 1
3. **定位 U 盘内 yum 源目录**（含 `repodata` 子目录的目录）：
   - `find $USB_MOUNT_POINT -maxdepth 3 -type d -name repodata`，取父目录
   - 多个 → 列出交互选择（或取第一个并提示）；无 → 提示"U 盘内未发现含 repodata 的目录"，退出 1
4. **复制到系统**：`mkdir -p $REPO_DEST` + `cp -r <源目录>/. $REPO_DEST/`；已存在非空 → 交互询问覆盖合并/跳过；DRY_RUN 只打印
5. **本地 yum 源配置**：写 `$YUM_REPO_FILE`
   ```
   [kylin-local]
   name=Kylin Local Repo
   baseurl=file://$REPO_DEST
   enabled=1
   gpgcheck=0
   ```
   已存在 → 提示并跳过（不覆盖）
6. **验证**：`ls $REPO_DEST | head`、`yum repolist`（失败不阻塞，仅提示）

### 3.4 status 子命令

- 输出：U 盘挂载点/设备、`$REPO_DEST` 是否存在及内容条目数（含 repodata 与否）、repo 文件是否存在及 baseurl、日志路径

### 3.5 umount 子命令

- root 检查；列出将卸载项（`$USB_MOUNT_POINT` 如已挂载）→ y 确认 → umount
- **不删除** `$REPO_DEST` 与 `$YUM_REPO_FILE`（本地源独立于 U 盘）；提示手动清理命令
- DRY_RUN=1 只打印

### 3.6 日志

- 每步操作写 `MOUNT_LOG`（mkdir -p 父目录），格式 `[时间] cmd: ... 结果:$?`

### 3.7 涉及文件

- 新增：`offline-stress-pkg/mount-iso.sh`
- 更新：`offline-stress-pkg/README.md`（包结构树 + 使用说明）
- 更新：`offline-stress-pkg/operation-manual.md`（新增一节）
- 重打：`offline-stress-pkg.zip`
- 设计/计划文档（combo/workflow）不改——本功能独立

## 4. 测试方案（tdd，stub 化）

沿用测试接缝，在 `.superpowers/sdd/2026-11-14-mount-iso/` 下 stub 验证：

1. **build RPM 定位**：U 盘含 rpm → 用 U 盘；否则 --rpm-dir；否则包内 rpms/；三者皆无 → 退出
2. **createrepo 调用**：伪造 CREATEREPO_BIN 记录调用参数；DRY_RUN 只打印
3. **构建落盘**：REPO_DEST 已存在非空 → 提示覆盖/跳过；U 盘挂载时写入 U 盘一份
4. **mount 流程**：伪造 lsblk 含 USB 盘 → 识别首分区；挂载点含 repodata → 源目录定位正确；复制 + repo 文件内容正确（baseurl=file:///opt/kylin-repo）；已存在不覆盖
5. **umount**：确认后卸载，不删本地源
6. **旧行为回归**：disk-mount.sh / stress-test.sh 不受影响

## 5. 非目标

- 不改既有 disk-mount.sh / stress-test.sh 逻辑
- 不自动格式化 U 盘（直接挂载已有文件系统）
- 不做 ISO 挂载/下载
- 本地源只写 $YUM_REPO_FILE，不动其它 repo
- 不自动安装 createrepo（缺失时提示安装命令）

## 6. 验收标准

- `build`：三种 RPM 来源优先级正确，createrepo 构建 + 落盘 REPO_DEST + 写入 U 盘
- `mount`：U盘挂载 → 复制 → 配置本地源，全程有日志；无 U 盘/无 repodata 优雅提示退出
- `status` / `umount` 可用；DRY_RUN 只打印不执行
- bash -n 语法通过；README / operation-manual.md 同步更新；zip 重打
