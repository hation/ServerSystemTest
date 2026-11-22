# diskwipe-iso v1.3.2 交付记录（init 零 U 盘 I/O 根治）

- 日期：2026-11-22
- 版本：v1.3.2
- 关联：设计 `docs/superpowers/specs/2026-11-22-diskwipe-iso-init-usb-hang-design.md`

## 交付内容

| commit | 内容 |
|---|---|
| `40a7600` | fix：init 阶段零 U 盘 I/O（删除 `dw_mount_log_media` 调用与函数）；日志改内存（/tmp/diskwipe-log，无条件创建）；新增 `dw_save_log_to_usb`（退出时尽力写 U 盘，timeout 兜底）；t4 重写（L1-L6）+ t3 I1 init 无 mount 断言 + t6 H9b 适配 |
| `85778e1` | release：v1.3.2 重打包（VERSION/README/冒烟） |

## 验证

- 测试 346 PASS（t1:89 / t2:61 / t3:45 / t4:46 / t5:37 / t6:68；run-all 全量 ALL PASS）。
- qemu 冒烟 15/15：菜单立即出现、无 U 盘挂载动作、列盘/清除 OK、日志内存 + 退出写 U 盘成功。
- `bash --posix -n src/*` 0 错误；isoinfo 校验 /diskwipe.version=1.3.2。

## 验收口径

- **进得去**：init 零 U 盘 I/O → 菜单必现（无论 U 盘是否异常）。
- **清得了**：清除算法未变（umount→wipefs→partprobe→验证）。
- **日志尽力**：会话日志在内存；0 退出时尽力写 U 盘；异常 U 盘提示"日志在内存、可抄录后断电"。

## 已知边界

- 退出时 U 盘 D 状态阻塞 → 退出挂起（timeout 无效）→ 清除已完成，提示可断电。
- 会话中途断电 → 内存日志丢失（工具可用优先的权衡）。
- 建议现场：U 盘用后正常卸载（安全弹出），减少 exFAT 脏卷触发。

## 待办

- 真机重测（README §10）；通过后 push（当前未推送）。
