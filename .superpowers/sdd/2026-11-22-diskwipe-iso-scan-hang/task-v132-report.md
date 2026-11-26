# diskwipe-iso v1.3.2 任务报告：根治「init 阶段 U 盘日志介质 I/O 卡死导致菜单进不去」

日期：2026-11-22 · 实现：subagent（diskwipe-iso v1.3.2）· 状态：DONE

## 1. 改动（v1.3.2 按设计实现）

| 文件 | 改动 |
|---|---|
| `diskwipe-iso/src/init` | 第 4 步重试循环删除 `dw_mount_log_media` 调用（保留 `mdev -s` + `sleep 2` 补建节点 3 轮）；**init 零 U 盘 I/O**（不挂载/不写测试/不探测）；注释同步 |
| `diskwipe-iso/src/lib.sh` | **删除 `dw_mount_log_media`**（死代码）+ 删除 `DW_LOG_PROBE` 接缝；**新增 `dw_save_log_to_usb <file>`**：枚举 U 盘可写分区候选（`timeout 3 lsblk -o NAME,TYPE,TRAN,PKNAME -l`，TRAN=usb 整盘→分区）→ blkid TYPE ∈ vfat|exfat|ntfs + 跳过卷标 VTOYEFI（均包 timeout 3）→ 逐个 `timeout 3 mount` → `cp` → `umount`（失败仅提示）；成功返回 0，全败/无候选返回 1；`dw_log` 注释/WARN 文案更新（内存日志语境，LOG_DEGRADED 防御保留） |
| `diskwipe-iso/src/menu.sh` | 日志**无条件写内存**：`LOG_DIR="${LOG_DIR:-/tmp/diskwipe-log}"`（tmpfs），启动始终 `mkdir -p` + 创建 `diskwipe-<ts>.log`（删除 `No writable log media found` 分支与 `DW_LOG_MEDIA` 依赖）；`dw_log_finish` 改为：写文件尾 → 打印 `Log kept in memory: $LOG_FILE` → `dw_save_log_to_usb` → 成功 `Cleanup log saved to USB` / 失败 `WARN: could not write log to USB (disk I/O blocked or no USB); log kept in memory: $LOG_FILE`；不再 umount /diskwipe-log |
| `diskwipe-iso/VERSION` | 1.3.1 → **1.3.2** |
| `diskwipe-iso/tests/t4_log.sh` | **重写**为新用例 L1-L6（见 §2） |
| `diskwipe-iso/tests/lib.sh` | 新增 **cp 假件**（记录调用 + 复制到 `$ROOT/mnt/`，内部用 `/usr/bin/cp` 防递归）；**移除 timeout.writetest / timeout.tee 开关** |
| `diskwipe-iso/tests/t3_init.sh` | stub 简化（去掉 lsblk/blkid/timeout 假件——init 不再探测介质）；I1 新增 `check_not_cmds 'mount /dev/'`（init 零 U 盘挂载）断言 |
| `diskwipe-iso/tests/t6_scan.sh` | H9b 由 `dw_mount_log_media` 改为 **`dw_save_log_to_usb` 包 timeout** 断言（lsblk/blkid/mount 均 `timeout 3`）；H1/H7 lsblk 计数按退出写 U 盘枚举调整 |
| `diskwipe-iso/README.md` | §1 新增 v1.3.2 更新日志；§6 清理日志改写（内存日志 + 退出尽力写 U 盘）；§9 测试计数/描述；§10 重测指引 v1.3.2；版本号/产物/冒烟清单/dd/Rufus/横幅 1.3.1→1.3.2（v1.3.1 历史段语义保留） |
| `diskwipe-iso/build-lib.sh` | 注释同步（`dw_mount_log_media` → 退出写 U 盘语境，无功能改动） |
| `tmp/dw-smoke-v132.sh` | 新增 v1.3.2 qemu 冒烟脚本（基于 v131 改造） |

## 2. 测试证据（单独跑全部 PASS，共 346 项）

| 组 | 项数 | 结果 | 说明 |
|---|---|---|---|
| t1_wipe | 89 | PASS | 无改动，回归通过 |
| t2_menu | 61 | PASS | 无改动，回归通过（退出路径新增 dw_save_log_to_usb 不产生 cmds） |
| t3_init | 45 | PASS | I1 新增「init 阶段零 U 盘挂载」断言；mdev -s 计数 4 次不变 |
| t4_log | 46 | PASS | 新用例全过（见下） |
| t5_ascii | 37 | PASS | 屏幕输出 ASCII 回归通过 |
| t6_scan | 68 | PASS | H9b 改造 + H1/H7 计数调整后全过 |

t4 新用例（L1-L6）：
- **L1** menu 无 U 盘 → 内存日志含文件头（version/session start/log media: memory）/盘清单/每盘结果/文件尾；退出时无候选 → `WARN: could not write log to USB`；清理照常；无 `No writable log media`
- **L2** menu 两轮全流程 → 单日志文件含两轮内容（4 行结果）；0 退出正常
- **L3** dw_save_log_to_usb 成功路径：跳过 VTOYEFI → 挂载 sdc2 → cp → umount；返回 0，日志复制到挂载点
- **L4** 挂载失败（mount.fail）→ 返回 1（降级提示）
- **L5** init 零 U 盘 I/O：src/init 与 src/lib.sh 均无 `dw_mount_log_media`；init 无调用行、无 `/dev/` 挂载形态
- **L6** dw_log 写内存正常（LOG_DEGRADED 未触发，无 WARN）

全量回归 `run-all.sh` **ALL PASS**（t1→t6 顺序执行，六组全过，末行「==== 全部测试: ALL PASS ====」，输出留档）。

## 3. 构建 + qemu 冒烟

- **构建**：`bash diskwipe-iso/build.sh` 成功 → `output/diskwipe-v1.3.2.iso`（77M）；isoinfo 校验全过：三个关键文件、双 console、/init 执行位、`initrd 内 /diskwipe.version = 1.3.2`、src 四脚本 dash -n 0 错误、模块全未压缩 .ko（267 个）。
- **qemu 冒烟**（`tmp/dw-smoke-v132.sh`，虚拟盘 vda=SYS(ntfs)/vdb=DATA/vdc=UNK + USB sda(VTOYEFI+DWLOGTEST)）：**15/15 断言 PASS**。

冒烟关键行（tmp/dw-smoke-v132.out / -keylines.txt）：

```
Mounted /proc → Disk driver modules loaded → Device nodes scanned   ← init 无 U 盘 I/O
  DiskWipe Tool 1.3.2 - Reset disks to uninitialized                ← 菜单立即出现（横幅 1.3.2）
Disks found: 3 (vda vdb vdc)
1 /dev/vda 1G unknown (VIRTIO) SYS / 2 /dev/vdb ... DATA / 3 /dev/vdc ... UNK
OK /dev/vda reset to uninitialized（vdb/vdc 同）
== session end [2026-11-22 08:11:19] ==
Log kept in memory: /tmp/diskwipe-log/diskwipe-20261122-081112.log
Cleanup log saved to USB                                          ← 退出尽力写 U 盘成功
USB 数据区实检：diskwipe-20261122-081112.log 存在，header「log media: memory (/tmp/diskwipe-log)」
exFAT/VTOYEFI 挂载消息：0 条（对比 v1.3.1 的 exFAT-fs 卡死现场——init 不再挂载 U 盘）
```

## 4. Commit

1. `40a7600 fix(diskwipe-iso): init 阶段零 U 盘 I/O（不再挂载日志介质），日志改内存 + 退出尽力写 U 盘，根治 U 盘 I/O 阻塞进不去`（src/ + tests/，7 文件）
2. `85778e1 release(diskwipe-iso): v1.3.2 零 U 盘 I/O 根治重打包（qemu 冒烟：横幅 1.3.2/列盘/三盘 OK/内存日志/退出写 U 盘全过）`（VERSION/README/冒烟脚本/注释同步，9 文件）

## 5. Concerns / 备注

- **`/diskwipe-log` mkdir**：dw_save_log_to_usb 保留 `mkdir -p /diskwipe-log`（挂载点；失败 `|| :` 容忍）。测试环境会在本机留下空目录（与旧 dw_mount_log_media 行为一致，非真实盘接触）。
- **退出时若 U 盘 I/O 阻塞**（内核 D 状态，timeout 亦挂）：dw_save_log_to_usb 的 mount 可能挂起——按设计属可接受（清理已完成，提示抄录后断电）。
- **cp 假件递归坑**：假 cp 内用裸 `cp` 会经 PATH 命中自身无限递归（首跑 t4 挂死已发现），改用绝对路径 `/usr/bin/cp` 修复。
- 内存日志默认路径 `/tmp/diskwipe-log`（initramfs rootfs 即 tmpfs），断电即失——依赖退出时写 U 盘或抄录。
