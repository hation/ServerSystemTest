# 压测后数据盘自动清理（wipefs 整盘清空）设计

- 日期：2026-11-21
- 状态：待评审
- 依据：用户 2026-11-21 现场反馈（fdisk 显示压测后 7.28TB 盘残留 EXT4 文件系统）+ 本轮 brainstorming 逐项确认

## 1. 背景与问题

用户现场反馈：硬盘压力测试结束后，数据盘上残留了 **EXT4 文件系统**（fdisk 显示 7.28TB 盘带 EXT4 分区/文件系统），此前"压测结束后不会有数据残留"（旧流程靠人工 wipefs/清盘），希望脚本自动完成清理，并额外提供"一键清空非系统盘、非U盘"能力。

现状梳理（已核实）：

- 数据盘由 `disk-mount.sh mount` 挂载/格式化（`--rebuild` 或默认模式空盘自动 `mkfs.ext4`），压测后盘上保留 EXT4 文件系统与分区表。
- `stress --hdd` 在盘上写 `stress.XXXX` 临时文件：正常跑满超时退出时 stress 自行删除；进程被 kill/断电时文件残留。
- 脚本从基线（056d050）至今**从无**自动清盘逻辑；操作手册 §3.4 仅要求人工 `disk-mount.sh umount`（只卸载、不删文件系统）。
- 系统盘压测目录 `/stresstest-hdd` 的文件由人工清理（手册 § 说明），本次保持不变。

## 2. 已确认口径（用户决策，不得偏离）

| 项 | 口径 |
|---|---|
| 清理粒度 | **整盘清空**：umount → `wipefs -a <整盘>`（清分区表+文件系统签名）→ partprobe，盘回到"无分区、无文件系统"的空白盘状态 |
| 通电数据安全 | 已核实：wipefs 只清块设备签名（LBA 逻辑层元数据），**不影响 SMART 通电时间/通电次数、固件、出厂信息**（存于固件服务区/PCB flash，普通块操作接触不到） |
| 清理时机 | ① oneclick 批次（all/full/hdd）**结束后自动清理**；② 提供**独立一键清理命令**（`disk-mount.sh clean`），两者都要 |
| 触发方式 | 自动清理**默认开启**，`--no-cleanup` 可关闭；一键清理命令默认 y/N 计划确认（--yes 跳过） |
| 清理范围（自动） | 仅本批压测涉及的数据盘（`/mnt/HDD*` 挂载盘） |
| 清理范围（一键） | **全部非系统盘、非U盘**（含未挂载但带 fs/分区表的旧盘、含挂了业务挂载点的盘——用户显式选择"全部清空"） |
| 系统盘 | 永不清理（根文件系统与 `/stresstest-hdd` 压测文件保持现状，人工清理） |
| 功能落位 | `disk-mount.sh` 新增 `clean` 子命令 + oneclick 菜单新增"清空数据盘"项 + oneclick 批次自动调用 |
| 退出码 | 0=全部成功/无需操作/取消；1=用法/前置错误/系统盘识别失败/存在失败盘 |

## 3. 目标

- `disk-mount.sh clean`：一键清空全部非系统盘、非U盘（含业务挂载点盘），卸载 + `wipefs -a` 整盘 + partprobe，回到空白盘。
- oneclick all/full/hdd 批次结束后自动清理本批数据盘（默认开启，`--no-cleanup` 关闭）。
- oneclick 菜单新增"清空数据盘"项。
- 文档（README / operation-manual / 命令执行逻辑）与打包（v1.1.3 → v1.2.0，双 zip）同步。

## 4. 非目标

- 不清理系统盘、不做 `/stresstest-hdd` 压测文件自动删除。
- 不做安全擦除（全盘覆写/dd zero/blkdiscard）——仅 wipefs 清签名，数据块内容不清零（fdisk 视角即为空白盘）。
- 不改 CPU/内存压测与判定。
- 不新增独立入口脚本（沿用 disk-mount.sh 子命令结构）。
- 不动 U 盘（TRAN=usb 一律排除）。

## 5. 反目标（即使能跑也算失败）

- 误清系统盘或 U 盘。
- 系统盘识别失败（SYS_ID_OK=0）时仍执行任何写操作。
- 自动清理误清本批之外/业务盘（自动清理范围严格限定 `cleanup-devices.txt` 记录的本批盘）。
- 一键清理在未确认（无 --yes）时静默执行。
- 破坏既有挂载/重建/umount 行为与既有回归套件。
- 压测结论被清理逻辑影响（清理失败不得改变 review 结论）。

## 6. disk-mount.sh clean 设计

### 6.1 CLI 与环境变量

```
bash disk-mount.sh clean [--disks sdb,sdc] [--yes] [--dry-run]
```

- 无 `--disks`：枚举全部候选盘（下述枚举范围）。
- `--disks sdb,sdc`：只处理指定盘；含系统盘/U 盘/不存在的盘 → 拒绝并退出 1。
  - `--disks` 兼容分区名：`sdb1`/`nvme0n1p1` 等自动经 lsblk PKNAME 归一为父整盘再校验（防用户传分区名导致误判"盘不存在"）。
- `--yes`：跳过 y/N 确认（供 oneclick 自动清理等自动化场景；仍然打印完整计划）。
- `--dry-run`：等价 `DRY_RUN=1`（保留环境变量兼容），只打印计划、零写操作、不写 mount.log；末尾输出 `（DRY RUN，未执行）`，退出码按计划判定。
- 新增接缝：`WIPEFS_BIN="${WIPEFS_BIN:-wipefs}"`（写入 disk-mount.sh 变量区）。
- `root_check` 前置（与 mount/umount 一致）；`SKIP_ROOT_CHECK=1` 本地测试跳过。

### 6.2 枚举范围（全部候选盘）

复用 `collect_non_sys_disks`（`disk_lines` 的 sd*/nvme*/vd*/mmcblk* TYPE=disk，`is_sys_disk_or_part` 硬跳过系统盘），再叠加两道过滤：

1. 系统盘 fail-closed：`SYS_ID_OK=0`（系统盘识别不可靠）且非 dry-run → 直接中止退出 1，零写操作；dry-run 仅告警继续打印计划（与 mount 一致）。
2. U 盘排除：新增 `disk_is_usb <name>`——`lsblk -P -o NAME,TRAN` 中该盘 `TRAN=usb` 即排除（与 mount-iso/usb-eject 的 TRAN 判定口径一致）。

`--disks` 显式指定时跳过枚举，直接对指定盘校验（系统盘→拒绝；U 盘→拒绝；不存在→拒绝）。

### 6.3 单盘清理步骤

```text
1) 收集该盘子树全部挂载点（disk_mountpoints <name>，含分区/LVM/RAID/crypt 后代）
   - 逐个 umount：先 cd 到非挂载点目录再 umount（复用既有"切目录再卸载"模式，避免 target is busy）
   - 任一挂载点 umount 失败 → 该盘标失败，跳过该盘（不 wipefs），继续其他盘
2) wipefs -a /dev/<name>            # 整盘：清分区表签名 + 盘内全部 fs/raid/PV 签名
3) partprobe /dev/<name>            # 刷新内核分区视图（可用时；失败仅告警，不判失败）
```

> 注：实现按更严口径：partprobe 失败判该盘失败——内核分区视图未刷新不报成功；与本节"失败仅告警"不同，为保守方向。

- 状态判定（计划阶段，用 `wipefs -n` 权威判定签名）：
  - 无挂载点且 `wipefs -n /dev/<name>` 输出为空 → "已是空白盘，无需清理"，跳过（良性，不计失败）。
  - `wipefs -n` 不可用/探测失败 → **fail-safe 照清**（空白盘清空也无害，保证零残留；避免 blkid 漏检残留签名——正是本次 7.28TB 场景）。
  - 有挂载点（含业务挂载点）→ 计划行列出**全部挂载点**，业务挂载点明确标注 `（业务挂载点，将一并卸载清空）`。
- 每步写 mount.log（`run_log`），与 mount/umount 同格式。
- 任一步失败仅跳过该盘，不中断其他盘；全部结束有失败盘 → 退出码 1，并列出失败盘与原因。

### 6.4 计划输出与确认

```text
==== 待清理盘（非系统盘、非U盘）====
  1  /dev/sdb  894G   挂载: /mnt/HDD01 → 卸载后 wipefs -a 整盘
  2  /dev/sdc  894G   挂载: /mnt/HDD02、/data（业务挂载点，将一并卸载清空） → 卸载后 wipefs -a 整盘
  3  /dev/sdd  894G   已是空白盘，无需清理（跳过）
  4  /dev/sde  894G   未挂载，带 EXT4/分区表 → 直接 wipefs -a 整盘
确认清空以上 N 块盘（y/N）：
```

- 默认打印计划后 y/N 确认（`y|Y` 才执行，其余取消退出 0）。
- `--yes` 跳过确认直接执行（计划仍打印）。
- `--dry-run`：打印计划 + `（DRY RUN，未执行）`，退出码按计划判定。

### 6.5 退出码

- 0 = 全部成功/全部无需清理/取消/全部良性跳过。
- 1 = 用法错误、含系统盘、系统盘识别失败（非 dry-run）、U 盘被指定、盘不存在、存在失败盘。

### 6.6 与既有命令的关系

- `clean` 与 `umount` 区别：umount 只卸载 `/mnt/HDD*` 挂载点；clean 卸载**任意**挂载点并 `wipefs -a` 整盘。
- `clean` 后盘回到空白 → 下次 `mount` 默认模式视为"无分区空盘"自动 mkfs（循环正常）。

## 7. oneclick 批次结束自动清理设计

### 7.1 开关与变量

- 新增 `CLEANUP`：默认 1（自动清理开启）；CLI `--no-cleanup` 置 0。
- oneclick.sh 变量区新增 `CLEANUP=1`；参数解析 `--no-cleanup) CLEANUP=0; shift`；`write_env_file` 记录 `CLEANUP=$CLEANUP`。
- usage/菜单"提示"段补充：`批次结束后自动清空本批数据盘（--no-cleanup 关闭）`。

### 7.2 本批盘记录（cleanup-devices.txt）

- `write_plan` 在 all/full/hdd 分支枚举 `/mnt/HDD*` 目录时，同步对每个目录 `findmnt -n -o SOURCE --target <dir>` 取设备，**经 lsblk PKNAME 归一为父整盘名**（默认模式挂载的是首分区，如 `sdb1` → `sdb`），去重写入 `$BATCH/cleanup-devices.txt`。
- `--no-hdd` 分支不写（无数据盘）。
- 目录未挂载（findmnt 失败）→ 不记录该设备（该任务启动时挂载点校验会失败，无盘可清）。

### 7.3 执行时机与命令

- 位置：`run_mode` 流程中 `run_review_all` 完成、summary 输出**之后**。
- 条件：`CLEANUP=1` 且 `mode ∈ {all,full,hdd}` 且 `NO_HDD=0` 且 `cleanup-devices.txt` 非空。
- 执行前预检（防误清，符合 §5 反目标）：
  - 过滤掉已不存在的盘（拔盘/掉盘）→ 在 summary 标注 `已跳过 N 块（设备已不存在）`，不导致整批失败。
  - 过滤掉当前存在**非 `/mnt/HDD*` 挂载点**的盘（清理时点出现了业务挂载）→ 该盘跳过，summary 标注 `已跳过（存在业务挂载点）` 并提示手动 `bash disk-mount.sh clean` 逐盘确认。
  - 剩余设备作为 `--disks` 列表。
- 命令（经 `show_run` 展示并落 commands.txt，遵守命令可见性约定）：

  ```
  bash $DM clean --disks sdb,sdc --yes
  ```

- 设备列表为空 → 打印"无数据盘，跳过清理"。

### 7.4 summary 标注

summary.txt 追加（在"自动挂载"段之后）：

- 清理成功：`数据盘清理: 已清空 N 块（sdb,sdc）`
- 清理失败（任一盘失败/命令退出非 0）：`数据盘清理: 失败（见 mount.log），请手动执行：bash disk-mount.sh clean`
- 未执行：`数据盘清理: 已跳过（--no-cleanup）` 或 `数据盘清理: 无数据盘`

### 7.5 失败策略与中断

- 清理失败**不改变压测 review 结论**、不影响批次退出码（压测结论优先）；仅标注 + 提示手动命令。
- 批次被 Ctrl-C/stop 中断：进程终止，自动清理不执行；用户手动运行 `bash disk-mount.sh clean` 兜底。
- 系统盘 `/stresstest-hdd`：不清理（范围天然不含——clean 排除系统盘）。

## 8. oneclick 菜单新增项

- `show_menu` 在项 9 与 0 之间新增：

  ```
  10) 清空数据盘（全部非系统盘、非U盘；卸载并 wipefs 整盘，需 y 确认）
  ```

- `menu_loop` 增加 `10) CLEANUP=0; run_mode clean`（复用 run_mode 分发，避免菜单项直接调外部脚本；`clean` 模式下 run_mode 直接 `exec bash $DM clean`，交互确认）。
  - 说明：菜单项调用的是**交互式一键清空**（不带 --yes），打印计划后需 y 确认，符合安全要求。
- `printf '请选择（0-9）'` → `请选择（0-10）`。
- CLI 也支持 `bash oneclick.sh clean`（子命令直达，等价菜单项 10）。

## 9. 版本与打包

- `VERSION`：1.1.3 → **1.2.0**（新增功能，次版本号 +1）。
- 重打 `offline-stress-pkg.zip`（日常）+ `offline-stress-pkg-v1.2.0.zip`（留档），两者内容一致；旧 zip 保留。

## 10. 测试计划

新增 `.superpowers/sdd/2026-11-21-hdd-cleanup/tests/`，沿用 lib.sh 假命令注入风格（接缝变量 + 假 PATH）。

### 10.1 disk-mount.sh clean

| 编号 | 场景 | 期望 |
|---|---|---|
| C1 | 默认枚举：两盘挂载 /mnt/HDD01、/mnt/HDD02 | 计划含两盘；y 确认后 `umount`×2 → `wipefs -a /dev/sdX`×2 → `partprobe`×2 |
| C2 | `--dry-run` | 完整计划、零写命令、mount.log 不存在、末尾 `（DRY RUN，未执行）` |
| C3 | `--yes` | 不出现确认提示，直接执行 |
| C4 | `--disks sdb` | 只处理 sdb，不出现 sdc |
| C5 | 系统盘识别失败（SYS_ID_OK=0） | 非 dry-run 中止且零写命令；dry-run 仅告警 |
| C6 | U 盘（TRAN=usb） | 不出现在计划，零命令 |
| C7 | 已是空白盘（`wipefs -n` 输出为空） | 计划显示"无需清理"，跳过，退出 0 |
| C8 | 业务挂载点盘（/data） | 计划列出 /data（标注业务挂载点），确认后 umount /data + wipefs（按用户决策全部清空） |
| C9 | umount 失败 | 该盘跳过（无 wipefs），其他盘继续，退出 1 |
| C10 | `--disks sda`（系统盘） | 拒绝并退出 1，零写命令 |
| C11 | `--disks 不存在的盘` | 拒绝并退出 1 |
| C12 | 无候选盘 | 输出"无非系统盘、非U盘可清理"，退出 0 |
| C13 | `--disks sdb1`（分区名） | 归一为 sdb，计划只含 sdb，正常执行 |
| C14 | `wipefs -n` 不可用/失败 | fail-safe 照清（不跳过） |
| C15 | `wipefs -a` 失败 | 该盘跳过继续其他盘，退出 1 |

### 10.2 oneclick 自动清理

| 编号 | 场景 | 期望 |
|---|---|---|
| O1 | all 批次结束（有数据盘） | 复盘后执行 `disk-mount.sh clean --disks <设备> --yes`，命令经 show_run 展示并落 commands.txt；summary 含"数据盘清理: 已清空" |
| O2 | `--no-cleanup` | 不执行 clean，summary 含"已跳过（--no-cleanup）" |
| O3 | `--no-hdd` | 无数据盘，不执行 clean，summary 含"无数据盘" |
| O4 | 清理失败（假 wipefs 返回非 0） | review 结论不变；summary 含"清理: 失败"与手动命令提示；批次退出码不变 |
| O5 | `oneclick.sh clean` 子命令 / 菜单项 10 | 调用 disk-mount.sh clean（交互确认），计划展示 |
| O6 | 清理时点盘已不存在 | summary 标注"已跳过 N 块（设备已不存在）"，命令只含现存盘 |
| O7 | 清理时点盘出现业务挂载点 | 该盘跳过并标注，summary 提示手动命令 |

### 10.3 回归

- `.superpowers/sdd/2026-11-16-hdd-align-field/tests/`（disk-mount 28 项 + stress 10 项 + oneclick 8 项）
- `.superpowers/sdd/2026-11-15-oneclick-stress/tests/run-all.sh`（76 项）
- `.superpowers/sdd/2026-11-15-spec-driven-stress-params/tests/run-all.sh`（135 项）
- `.superpowers/sdd/2026-11-15-oneclick-command-visibility/`（69 项）
- `.superpowers/sdd/2026-11-15-dirs-space-path/tests/run-all.sh`（91 项）
- 命令可见性回归：自动清理命令必须出现在 commands.txt（不因 `--quiet` 丢失落盘）。

## 11. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 误清盘（业务/系统/U 盘） | clean 枚举硬排系统盘（fail-closed）与 U 盘（TRAN=usb）；默认 y/N 确认；`--disks` 指定盘逐项校验 |
| 自动清理误清非本批盘 | 范围严格限定 cleanup-devices.txt（本批挂载盘），不枚举全盘 |
| wipefs 后内核旧分区视图 | umount 全部挂载点后再 wipefs，随后 partprobe 刷新 |
| 清理失败未被注意 | summary 明确标注 + 打印手动命令；不静默 |
| 业务盘"全部清空"破坏业务数据 | 用户显式决策（确认口 2026-11-21）；计划明确列出业务挂载点并标注；默认强制 y/N 确认 |
| 与"默认不清盘"安全原则张力 | 自动清理仅限本批测试盘且默认开启可关闭（--no-cleanup）；一键清理需确认；文档明示 |
| 回归破坏 | clean 独立子命令；自动清理在复盘后执行，不动 review 逻辑；既有假件/接缝兼容 |

## 12. 文档与打包同步

- `README.md`：挂载章节后补"压测后清理"：`disk-mount.sh clean` 用法、`--no-cleanup`、菜单项 10、wipefs 语义与通电数据说明。
- `operation-manual.md`：硬盘压测章节补清理流程（自动 + 一键）；"测试完成后卸载"章节改为"测试完成后清理"。
- `docs/命令执行逻辑.md`：补 `clean` 子命令与自动清理的执行逻辑与行号引用（按函数所在 lib 计）。
- 打包：v1.2.0 双 zip；核对工作区与包内 SHA256 一致。

## 13. 设计者已定的决定（builder-check 后补充）

- **分区名归一**：`cleanup-devices.txt` 记录父整盘名（lsblk PKNAME）；`clean --disks` 兼容分区名并归一父盘。原因：默认模式挂载首分区（`/dev/sdb1`），若只认整盘名会自动清理在所有默认挂载场景失效。
- **自动清理预检**：清理时点过滤已不存在的盘与出现业务挂载点的盘（跳过并标注），保证自动路径不误清业务数据；一键命令仍按用户决策"全部清空"。原因：反目标要求自动清理不误清业务盘。
- **空白盘判定**：`wipefs -n` 权威列出签名（能检出 blkid 漏检的残留签名，正是本次 7.28TB 场景）；探测失败 fail-safe 照清。原因：保证零残留优先。
- 业务挂载点计划文案、`run_mode clean` 分发细节、卸载顺序、测试假件组织方式等仍留给实现者按既有风格自决。
