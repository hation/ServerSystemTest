# task-kylin 报告：diskwipe-iso v1.4.0 Kylin 内核构建模式（解决 Ubuntu 内核 USB 不兼容启动卡死）

日期：2026-11-22　｜　分支基线：`bd958ad`（v1.3.3）

## 1. 状态

**完成**。v1.4.0 Kylin 内核构建模式已实现：构建（Kylin 内核 + 白名单依赖链模块 + amd-ucode 固件）、构建校验（isoinfo + Kylin 断言）、qemu 冒烟（Kylin 内核 iso 启动，1G virtio 盘 + 虚拟 U 盘）**PASS**、既有回归 t1-t6 全 PASS（355 项）、两个 commit 已提交、产物 `output/diskwipe-v1.4.0.iso`（40M）。

## 2. 背景与设计落地

真机根因：Ubuntu 内核 xhci/USB 栈与该海光服务器 Microchip hub 不兼容（dmesg `hub_event hogged CPU`）→ 启动卡死；该服务器 Kylin 4.19 内核系统运行正常。v1.4.0 起构建支持**内核双模式**（auto/ubuntu/kylin），检测到 `diskwipe-iso/kylin-src/boot/vmlinuz-4.19*` 即自动用 Kylin 内核。

### Kylin 材料核对（已实测确认）

- 内核：`kylin-src/boot/vmlinuz-4.19.90-89.11.v2401.ky10.x86_64`（10.7M bzImage；`strings` 明文段含 `4.19.90-89.11.v2401.ky10.x86_64`，可作校验证据）。
- 模块：`kylin-src/modules/4.19.90-89.11.v2401.ky10.x86_64/`，2659 个 `.ko.xz`（xz 压缩），`modules.dep/modules.alias/modules.builtin` 齐全。
- 白名单模块核对结果：`usb-storage`（非 `usb_storage`）、`uas`、`ahci/libahci/libata`、`nvme/nvme-core`（依赖 `nvme-common`）、`mpt3sas`（依赖 `raid_class+scsi_transport_sas`）、`megaraid_sas`、`virtio_blk`、`sd_mod`、`nls_iso8859-1`、`vfat/fat`（vfat 依赖 fat）全部存在；**`xhci_pci/xhci-hcd/usbcore/ehci/ohci/scsi_mod/virtio_pci/virtio` 为内核内建**（modules.builtin，无模块文件——这正是 Kylin 内核 USB 栈兼容的关键）；**`exfat`/`ntfs3` 无模块**（Kylin 4.19 未引入）→ 从 Kylin 白名单移除（缺失不中断）。
- 固件：`kylin-src/firmware/amd-ucode/`（10 文件，84K）。

### 代码改动

- **`build-lib.sh`**：
  - 新增 `DW_KYLIN_MODULES` 白名单（Kylin 文件名形态）与 `dw_modules_kylin()`：白名单定位 `.ko.xz`（缺失跳过不中断）→ 一次 awk 读 `modules.dep` 建依赖图 + DFS 解析依赖链（实测 17 个模块，含 nvme-common/scsi_transport_sas/raid_class/fat）→ 按相对路径拷入 rootfs `/lib/modules/<kver>/` → `xz -d` 解压为 `.ko`（busybox 无 xz 解压）→ `modules.dep/modules.alias/modules.builtin/modules.order/modules.symbols/modules.softdep/modules.devname` 拷入并 `sed 's/\.ko\.xz/.ko/g'` → 固件仅拷 `amd-ucode` 到 `lib/firmware/`。
  - `DW_APT_PKGS` 增加 `xz-utils`（Kylin `.ko.xz` 解压）。
  - `dw_assemble_rootfs` 增加 mode 参数，2.3 步分支（kylin → dw_modules_kylin；ubuntu → 原逻辑不变）。
  - `dw_write_bootfiles` 增加 proj/mode 参数：kylin 模式 vmlinuz 取自 `kylin-src/boot/vmlinuz-<kver>`（/mnt/c 世界可读，无需 sudo，chmod 0644）。
  - `dw_verify_iso` 增加 mode 参数：6.5b 追加「无 `.ko.xz` 残留」断言；6.6 Kylin 追加「boot/vmlinuz `strings` 检出 `4.19.90`」+「关键模块 ahci/usb-storage/nvme 为未压缩 `.ko`」。
  - `dw_build_iso`：`DW_KERNEL_MODE`（auto 默认，检测 kylin-src 即切 kylin；显式 ubuntu|kylin 覆盖）+ kver 推导分支。
  - **实证修正（设计偏离点）**：awk 依赖解析原用命令行 `SEEDS=...` 赋值——gawk 管道 stdin 模式下**命令行 VAR=value 不生效**（实测 SEEDS 为空、解析结果空），改为 `-v SEEDS=...` 后正确（17 模块）。
- **`src/init`**：新增 `case "$(uname -r)" in *ky10*)` 切换 Kylin 白名单 `ahci libahci libata nvme nvme-core mpt3sas megaraid_sas virtio_blk sd_mod usb-storage uas nls_iso8859-1 vfat fat`（剔除内建模块与无模块的 exfat/ntfs3；`usb-storage` 文件名形态；vfat/fat 为模块）；依赖链由 busybox modprobe 按 modules.dep 自动带入。
- **`build.sh`**：可选参数 `[kylin|ubuntu|auto]`（默认 auto），`export DW_KERNEL_MODE` 经 WSL 透传（WSL 继承 Windows 环境变量）。
- **`.gitignore`**：新增 `kylin-src/`（解压目录不入库）；`kylin-src-20261122.tar.gz`（425M）作为构建材料入库。
- **`kylin-kernel-export.sh`**：已有脚本，保留并入库（Kylin 服务器一键提取 boot/modules/firmware）。

## 3. 测试结果

### 构建校验（PASS）

`build-lib` 直跑 + `build.sh kylin` 入口双验证，关键输出：

```
==> 内核模式：kylin
==> 使用内核：4.19.90-89.11.v2401.ky10.x86_64
     Kylin 模块提取：白名单 + 依赖链共 17 个 .ko.xz
     已把 17 个 .ko.xz 模块解压为 .ko
     modules.dep/modules.alias 等已拷入并 sed 改后缀（.ko.xz → .ko）
     固件：amd-ucode CPU 微码已拷入 lib/firmware（84K）
     Kylin 模块目录：4.3M
     initrd.img：4.6M
     iso：40M
     校验通过：initrd 内 /diskwipe.version = 1.4.0
     校验通过：src 四脚本 dash -n 语法 0 错误
     校验通过：initrd 内模块全部为未压缩 .ko（共 17 个，无 .ko.zst/.ko.xz 残留）
     校验通过：boot/vmlinuz 为 Kylin 4.19 内核（strings 检出 4.19.90 版本串）
     校验通过：initrd 内关键模块 ahci/usb-storage/nvme 均为未压缩 .ko
```

### qemu 冒烟（**PASS**，`tmp/dw-smoke-v140.sh`，盘布局同 v133：vda ntfs→SYS、vdb 空白→DATA、vdc 分区无 fs→UNK、sda USB(VTOYEFI+DWLOGTEST)）

关键行（Kylin 内核启动证据 + 全流程）：

```
Linux version 4.19.90-89.11.v2401.ky10.x86_64 (root@localhost.localdomain) (gcc version 7.3.0 (GCC)) #1 SMP ...
Command line: BOOT_IMAGE=/boot/vmlinuz console=tty0 console=ttyS0,115200n8
DiskWipe Tool 1.4.0 - Reset disks to uninitialized
Scanning disks... (please wait)
Disks found: 3 (vda vdb vdc)
1  /dev/vda  1G   unknown (VIRTIO)  SYS
2  /dev/vdb  256M  unknown (VIRTIO)  DATA
3  /dev/vdc  256M  unknown (VIRTIO)  UNK
OK /dev/vda reset to uninitialized
OK /dev/vdb reset to uninitialized
OK /dev/vdc reset to uninitialized
Exited. You may power off or reboot after done.
Log kept in memory: ...
Cleanup log saved to USB
=== smoke verdict: PASS ===
```

14 项断言全 PASS（含 `no ERROR line`）；退出日志真实落虚拟 U 盘（`diskwipe-20261122-100541.log`，version 1.4.0、三盘 OK）。

### 既有回归 t1-t6（全 PASS，355 项）

| 组 | 项数 | 结果 |
|---|---|---|
| t1_wipe | 89 | ALL PASS |
| t2_menu | 61 | ALL PASS |
| t3_init | 45 | ALL PASS |
| t4_log | 46 | ALL PASS |
| t5_ascii | 37 | ALL PASS |
| t6_scan | 77 | ALL PASS |
| **合计** | **355** | **ALL PASS** |

- POSIX 语法：`dash -n build-lib.sh / build.sh / src/*` 0 错误。
- 说明：t3_init 的 host `uname -r`（Git Bash MSYS）不含 `ky10` → Ubuntu 白名单路径不变，回归不受 init 的 Kylin 分支影响。

## 4. 版本与 README

- `VERSION`：1.3.3 → **1.4.0**（新构建模式，次版本 +1）。
- `README.md`：§1 新增 v1.4.0 changelog（Kylin 内核构建模式——Ubuntu 内核与该海光服务器 USB 不兼容的解决方案；Kylin 4.19 无 exfat/ntfs3 的注意点）；§2 目录结构补 `kylin-kernel-export.sh`/`kylin-src-<日期>.tar.gz`；§3 构建说明加「Kylin 内核材料准备」三步与 `build.sh kylin|ubuntu|auto` 三命令、依赖清单加 xz-utils、kylin 模式构建流程与校验说明；§4/§5/§7/§10 当前版本引用精确替换为 1.4.0（历史段 v1.3.1/v1.3.2/v1.3.3 语义未动）；§8 驱动兜底改为 v1.4.0 Kylin 模式自动化做法（旧手动替换路径保留并标注仅 ubuntu 模式）；§10 重测指引改为 v1.4.0 Kylin 内核版（重点：内核版本行 + 菜单必现）。

## 5. 提交与产物

- 提交 1：`acb3146` `feat(diskwipe-iso): 新增 Kylin 内核构建模式（解决 Ubuntu 内核 USB 不兼容启动卡死）`（build-lib.sh/build.sh/src/init/.gitignore/kylin-kernel-export.sh/kylin-src-20261122.tar.gz，6 files，+299/-20）
- 提交 2：`b74c97f` `release(diskwipe-iso): v1.4.0 Kylin 内核版重打包`（VERSION/README.md，2 files，+40/-26）
- 产物：`diskwipe-iso/output/diskwipe-v1.4.0.iso`（40M，BIOS+UEFI 双引导）
- 材料：`diskwipe-iso/kylin-src-20261122.tar.gz`（425M，入库）；`kylin-src/` 解压目录（986M）git 忽略不入库。
- 工作区其余未跟踪文件（docs/tmp/.superpowers 等）未纳入本次提交。

## 6. Concerns

- **Kylin 4.19 无 exfat/ntfs3 模块**：Kylin 模式退出写日志 U 盘仅支持 vfat/ntfs；exfat U 盘日志写失败会降级为内存日志（`WARN: could not write log to USB ...`），不影响清理。README §1/§10 已注明。
- **固件仅 amd-ucode**：amdgpu/网卡等固件未拷（initramfs 体积控制）；磁盘/网卡驱动所需固件缺失不阻塞（目标驱动已在 Kylin 服务器确认可用）。若现场某驱动加载报 firmware 缺失，把对应固件目录拷入 `kylin-src/firmware/` 或扩展 `dw_modules_kylin` 固件清单即可。
- **qemu 冒烟为虚拟化环境**（virtio + nec-usb-xhci）：验证了 Kylin 内核引导/模块/菜单/清除/日志全链路；真机海光服务器 USB 兼容性需 §10 真机复测最终确认（本任务核心目标即消除该根因）。
- **tar.gz 425M 入库**：仓库体积显著增大；按任务要求作为构建材料保留（无 LFS），后续可评估换 LFS/外部存储。
