# U 盘安全弹出脚本设计（usb-eject.sh）

- 日期：2026-11-14
- 状态：待评审
- 新增文件：`offline-stress-pkg/usb-eject.sh`
- 需求：一键"退出/弹出 U 盘"。默认卸载该 U 盘**所有**挂载点（含 `/mnt/usb` 与桌面自动挂载的 `/run/media/...`），不断电；可选 `--poweroff` 断电弹出。多块 U 盘时自动检测并交互选择。

## 1. 需求确认（已与用户对齐）

- 弹出方式：默认**仅卸载挂载点**；`--poweroff` 可选断电（`udisksctl power-off`，失败回退 `eject`）
- 多 U 盘：自动检测；只有一块直接处理，多块列出让用户输入序号/盘名选择
- 脚本随 `offline-stress-pkg` 交付，英文文件名
- 只处理 USB 设备（`TRAN=usb`），拒绝非 USB 设备

## 2. 用法

```
bash usb-eject.sh                 # 自动检测（单盘直接卸；多盘交互选择），仅卸载
bash usb-eject.sh --poweroff      # 卸载后断电弹出
bash usb-eject.sh --disk sdb      # 直接指定 U 盘整盘名（非交互环境用）

测试接缝（环境变量）:
  DRY_RUN=1           只打印计划不执行
  SKIP_ROOT_CHECK=1   跳过 root 检查（本地测试）
  LSBLK_BIN           块设备查询命令（默认 lsblk，测试可伪造）
  MOUNT_LOG           操作日志（默认 /root/stress-test/mount.log）
  POWEROFF_BIN        断电命令（默认 udisksctl，测试可伪造）
```

## 3. 流程

1. root 检查（非 root 提示 `sudo bash usb-eject.sh`）
2. 扫描 `lsblk -P -o NAME,SIZE,TYPE,TRAN,MOUNTPOINT`，取 `TYPE==disk && TRAN==usb` 的盘；无 → 提示"未检测到 USB 盘"退出 1
3. 选盘：单盘自动；多盘列出（盘名/容量/当前挂载点）→ 输入序号或盘名；`--disk` 指定时校验确为 USB 盘，否则拒绝
4. 收集该盘及其所有子分区的 `MOUNTPOINT`（含 `/run/media/...`），逐个 `umount`（先子分区后整盘）
5. 失败（busy/占用）：提示占用排查命令（`fuser -vm` / `lsof +f -- <挂载点>`，命令不存在则跳过），记录日志，最终退出 1
6. 验证：再次读取该盘所有 `MOUNTPOINT`，全部为空才算成功
7. `--poweroff`：`udisksctl power-off -b /dev/<disk>`；失败回退 `eject /dev/<disk>`；均失败仅警告（卸载已完成，仍可安全拔出）
8. 每步写 `MOUNT_LOG`；成功输出"U 盘 /dev/sdX 已卸载，可安全拔出"

## 4. 安全

- 只处理 `TRAN=usb` 设备；`--disk` 指定非 USB 盘直接拒绝
- 不删除任何数据、不格式化
- 不卸载系统盘（USB 系统盘属极端场景，`df /` 识别命中则拒绝）

## 5. 涉及文件

- 新增 `offline-stress-pkg/usb-eject.sh`
- 更新 `usb-mount-guide.md` 第 5 节（补脚本方式）、`README.md`（结构树 + §10 一句话）、`operation-manual.md` §12
- 重打 `offline-stress-pkg.zip`

## 6. 测试（stub 化）

`.superpowers/sdd/2026-11-14-usb-eject/`：无盘退出 1；单盘自动卸载；多盘交互选择；`--disk` 指定非 USB 盘拒绝；`/run/media` 挂载点也被卸载；busy 卸载失败退出 1；`--poweroff` 调用伪造 POWEROFF_BIN；DRY_RUN 只打印；`bash -n` 通过。

## 7. 非目标

- 不格式化、不分区、不写数据
- 不改 `disk-mount.sh` / `stress-test.sh` / `mount-iso.sh` 逻辑
- 不自动安装 udisksctl/eject
