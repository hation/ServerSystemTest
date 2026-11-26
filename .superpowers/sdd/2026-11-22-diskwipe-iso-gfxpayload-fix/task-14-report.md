# Task 14 报告 — v1.5.14 lsblk 原始输出诊断 + 减少重试刷新噪音

- 状态：**DONE**
- commit：`873f09c`（main，HEAD）
- 一行测试摘要：tests t1-t6 全 PASS（77 项）+ qemu A（UEFI 有盘全流程+RAW lsblk）/B（-vga none 无盘 read -t 真实等待+消息每 10 轮一次）/C（BIOS 21 项）全 PASS

## 改动 diff（3 文件，+52/-12）

### 1. `diskwipe-iso/src/menu.sh`（+22/-8）

- **RAW lsblk 原始输出诊断**（在 `RAW enum ml=[$ml]` 之前）：
  ```sh
  dw_progress "RAW lsblk: $(lsblk -o NAME,SIZE,TYPE,MODEL,TRAN,MOUNTPOINT 2>&1 | tr '\n' '|')"
  ```
  （走 kmsg 双通道，不刷屏幕；定位真机 sda「未就绪/不存在」vs「lsblk 有输出但 awk 解析过滤掉」）
- **等待换 `read -t`**（无盘重试路径）：
  ```sh
  # v1.5.14：sleep 在真机严重失真（5s 实际 ~0.17s → 刷新疯狂）；read -t 用 select 超时，
  # 若时钟正常则 5s 真实等待（等待期间用户按键可提前跳过——tty0 已重定向）。
  read -t 5 dummy < /dev/tty0 2>/dev/null || true
  ```
- **重试消息每 10 轮一次**：
  ```sh
  dwnoretry=$((dwnoretry + 1))
  if [ $((dwnoretry % 10)) -eq 1 ]; then
      dw_log "No wipable disks found yet (retry $dwnoretry). Retrying... (you may power off anytime)"
      dw_progress "no disks, retry $dwnoretry (never auto poweroff/reboot)"
  fi
  ```
- 顶部/循环注释同步更新（交互逻辑零改动；未触碰 lib.sh/wipe.sh/build-lib.sh/isolinux/grub.cfg/embedded/BOOTX64.EFI）

### 2. `diskwipe-iso/VERSION`：`1.5.13` → `1.5.14`

### 3. `diskwipe-iso/tests/t2_menu.sh`（+30/-4，测试适配）

- M6：RAW lsblk 诊断每轮多一次 lsblk 调用 → 假 lsblk 计数阈值 `n -ge 4` → `n -ge 5`（前 4 次调用无盘表 = 枚举+RAW 各 2 轮 → 2 轮重试）
- M6 断言改：`retry 3` → `check_count 'No wipable disks found yet' 1`（每 10 轮一次降噪）+ `check_not_out 'retry 2'`；`check_cmd_count 'sleep 5' 3` → `check_not_cmds 'sleep'`（read -t 内建不可经假件记录）；新增 bash -x xtrace 断言 `read -t 5 dummy`（`/dev/tty0` 在假 /dev tmpfs 不存在 → 立即失败 `|| true`）
- M10：新增 `RAW lsblk:` kmsg 载荷断言

t1/t3/t4/t5/t6 无需改动（RAW 诊断走 kmsg 不进 stdout → ASCII 断言不受影响；裸 lsblk 无 timeout 前缀 → H1 `timeout 3 lsblk` 计数 4 不变；H7 枚举失败路径不达 RAW 诊断）。

## 构建关键行（WSL Kylin 模式，`tmp/build-v1514.sh`）

```
==> 内核模式：kylin（kylin = 使用 kylin-src 提取的 Kylin 4.19 内核...）
==> 使用内核：4.19.90-89.11.v2401.ky10.x86_64
     VERSION → /diskwipe.version（1.5.14）
     initrd.img：5.0M
     iso：39M
  ✓ 构建成功：/mnt/c/.../diskwipe-iso/output/diskwipe-v1.5.14.iso（大小 39M）
  isoinfo 校验全部通过（含 initrd 内 /diskwipe.version = 1.5.14、src 四脚本 dash -n 0 错误、无 usb-storage.ko）
```

## 验证断言输出

### tests t1-t6（WSL，勿用 Git Bash）
`bash diskwipe-iso/tests/run-all.sh` → **通过 77 项，失败 0 项，全部测试: ALL PASS**
（t2 新增断言关键行：`无盘重试等待走 read -t 5 dummy（v1.5.14 替代 sleep）` PASS、`重试 2 轮仅打印 1 条消息` PASS、`RAW lsblk 原始输出诊断行（kmsg 载荷）` PASS）

### qemu A（UEFI -vga std 有盘全流程，`tmp/dw-smoke-uefi-v1514.sh`）
`=== smoke verdict: PASS ===`；关键断言全 PASS：`RAW lsblk:`、`RAW enum ml=`、`DiskWipe Tool 1.5.14`、三盘 SYS/DATA/UNK、OK x3、Exited、日志降级 WARN + Log kept in memory、无 ERROR、U 盘无日志文件。

### qemu B（-vga none 无盘，`tmp/novid-v1514.sh`）
`=== novid verdict: PASS ===`；关键证据：
- **read -t 真实等待**：`retry 1 @37.2s` → `retry 11 @99.3s`（每 10 轮 ≈62s = 5s×10 + 枚举开销；v1.5.13 sleep 失真时每轮 ~1s 同窗口内 150 轮）
- **消息频率**：150s 内仅 4 条消息，retry 编号全为 1/11/21（%10==1），断言 `≤6 条` PASS（sleep 失真时 ≥15 条）
- RAW lsblk 诊断行出现（无盘载荷为空，真机 sda 存在时含 sda 行）
- qemu exit=124（timeout 收尾，menu 永不退出）；无 reboot/-f/关机字符串

### qemu C（BIOS isolinux 有盘，`tmp/dw-smoke-v1514.sh`）
`=== smoke verdict: PASS ===`；21 项关键行全 PASS（ISOLINUX 6.04、Linux 4.19.90、RAW lsblk、DiskWipe Tool 1.5.14、三盘、OK x3、Exited、降级、无 GNU GRUB/ERROR/Only boot media/No writable log media）。

## 验证脚本留档
- `tmp/dw-smoke-uefi-v1514.sh` / `tmp/novid-v1514.sh` / `tmp/dw-smoke-v1514.sh`（对应 A/B/C）
- `tmp/build-v1514.sh`、输出留档 `tmp/dw-smoke-uefi-v1514.out(.clean)`、`tmp/novid-v1514.out`、`tmp/dw-smoke-v1514.out(.clean)`、`tmp/build-v1514.log`

## concerns

1. **RAW lsblk 裸命令不带 timeout**（brief 指定文本）——真机 U 盘 I/O 阻塞时该命令替换可能拖慢该轮枚举；但诊断价值优先，且仅在枚举成功轮执行。
2. **read -t 在真机 select 时钟若同样失真**则等待仍会偏短——qemu 已验证真实 5s（retry 间隔 62s/10 轮），真机待现场确认；消息降噪已独立生效（无论轮速，仅每 10 轮打一次）。
3. M6 计数阈值 4→5 依赖 menu 每轮「枚举+RAW」恰好 2 次 lsblk 调用——已按当前实现精确计算并通过；若 menu 后续增加/减少 lsblk 调用需同步调整该阈值。
