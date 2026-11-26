# Task 12 brief — v1.5.12 枚举诊断（ml 原文）+ 勾选兜底 + reboot 强制

## 背景（v1.5.11 真机新问题）

v1.5.11（工作树改动，未 commit）真机已测：**输入修复生效**（/dev/tty0 成功，用户能输入），
但暴露新问题：
1. **设备名提取失败**：日志 `Disks found: 1 ()`（设备清单空）+ 盘列表显示 `1 /dev/ UNK`
   （`/dev/` 后设备名空）+ 用户回车全选 → `No disks selected`（勾选 0 个）。**根因**：
   枚举/格式化后的设备字段为空（qemu 正常，真机特有——需诊断 ml 原文定位）。
2. **reboot 未生效**：`rebooting in 10s` 后 menu 继续循环（busybox reboot 返回未重启）。
3. **盘类型 UNK**（blkid 探测慢/超时，不影响清除，暂不处理）。

## 任务（精确，基于当前工作树——含 Task 11 未 commit 改动）

### 1. `diskwipe-iso/src/menu.sh`：枚举诊断（定位设备名空）
在 `ml="$(dw_enum_disks)"`（约 81 行）后、显示盘列表前，加：
```
dw_progress "RAW enum ml=[$ml]"
```
（kmsg 输出枚举原文——真机屏幕可见，定位设备名空/格式异常的根因；qemu 正常流程不受影响）

### 2. `diskwipe-iso/src/menu.sh`：勾选兜底（227-238 行）
`mdev="${mline%% *}"` 后加兜底：若 mdev 为空，fallback 用 mtab 对应行的设备字段（| 分隔
第一个字段）。实现：勾选循环内提取 mdev 为空时，从 mtab 行补：
```
# v1.5.12 兜底：枚举行设备字段异常为空时，从格式化行（mtab）补设备名
if [ -z "$mdev" ]; then
    mtabline="$(printf '%s\n' "$mtab" | sed -n "${mi}p")"
    mdev="${mtabline%%|*}"
fi
```
（`sed -n` 按行号取；POSIX 兼容）

### 3. `diskwipe-iso/src/menu.sh`：reboot 强制 + fallthrough 保护
无盘重试后（`no disks after retries` 段）：
- `reboot` → `reboot -f`（busybox 强制重启，不依赖 init 守护）
- **fallthrough 保护**：`reboot -f` 后 `sleep 2`，若仍返回（未重启）→ 打印提示 + `continue`
  重新枚举（此时若盘已就绪则正常；避免无限 reboot）：
```
dw_progress "no disks after retries, rebooting in 10s"
sleep 10
reboot -f 2>/dev/null || true
sleep 2
dw_progress "reboot ineffective, re-enumerating"
continue
```

### 4. `diskwipe-iso/VERSION`：`1.5.10` → `1.5.12`（含 Task 11 的 1.5.11 未发布，直接到 1.5.12）。

### 5. 重新构建（WSL Kylin 模式）：`output/diskwipe-v1.5.12.iso`。

## 禁止改动

- src/lib.sh、src/wipe.sh、build-lib.sh、isolinux、grub.cfg、embedded、BOOTX64.EFI、xorriso。

## 验证（必须全部通过）

- **qemu A**（UEFI -vga std 有盘，参考 tmp/dw-smoke-uefi-v1511.sh 改 VERSION 1.5.12）：
  全流程（DiskWipe Tool 1.5.12、三盘、OK x3、Exited、日志降级）+ `RAW enum ml=` 诊断行。
- **qemu B**（-vga none 无盘，参考 tmp/novid-v1511.sh）：重试 → rebooting in 10s →
  reboot -f fallthrough 保护（reboot ineffective → re-enumerating）。
- **qemu C**（BIOS isolinux 有盘）：21 项回归（VERSION 1.5.12）。
- **tests t1-t6**（WSL 跑）：适配（RAW enum 诊断行、勾选兜底、reboot -f）。全部 PASS。
- 验证脚本留档 tmp/dw-smoke-uefi-v1512.sh / tmp/novid-v1512.sh / tmp/dw-smoke-v1512.sh。

## 提交

一次 commit（含 Task 11 + Task 12 全部工作树改动）：
`fix(diskwipe-iso): 枚举原文诊断 + 勾选设备名兜底（真机设备字段空致 No disks selected）+ reboot -f 强制与 fallthrough 保护；v1.5.12 重打包`

## 报告

写 `task-12-report.md`：改动 diff、构建关键行、A/B/C+tests 断言输出、commit hash。
返回：状态、commit hash、一行测试摘要、concerns。