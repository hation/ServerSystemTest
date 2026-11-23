# 计划：修复 auto 机型判定（逻辑线程优先）

- 日期：2026-11-21
- 版本：v1
- 状态：待执行

## 背景

`stress-test.sh start ... --model auto` 的机型判定在 [stress-lib-commands.sh L74-86](../../offline-stress-pkg/stress-lib-commands.sh) 以**内存大小为主判据**：`mem>=800G→7380；nproc>=120→7380；nproc>=90→7360；否则 5380`。

缺陷：一台 **5380 双路（32 物理核/64 逻辑线程）+ 994G 内存（16×64G）**的机器被误判为 7380（标称 128 线程），start.log 随即输出"偏差 50%，疑似单路 CPU"的**误报警**。机型虽只用于标注/交叉校验、不影响参数，但误导用户（以为 CPU 应推导 90 而实际是 45——45 对 64 线程的 full 规则是正确的）。

用户确认修复（AskUserQuestion：修复，走 superpowers/SDD 流程）。

## 目标

`auto` 机型判定以**实测逻辑线程为主判据**，内存仅在线程识别失败时兜底，消除"5380/7360 + 大内存 → 误判 7380"。

## 改动清单

### Task 1：修改 stress-lib-commands.sh 的 auto 判定逻辑

位置：L74-86。新逻辑：

```bash
# 机型解析（缺省 auto）：逻辑线程为主判据（5380=64、7360=96、7380=128）；
# 线程识别失败（n=0）时按内存兜底；仅用于报告标注与交叉校验，不影响参数
if [ "$model" = "auto" ]; then
    local mem_gb n
    mem_gb=$(awk '/^MemTotal:/{printf "%.0f", $2/1048576}' "$MEMINFO_FILE" 2>/dev/null)
    [ -z "$mem_gb" ] && mem_gb=0
    n=$(logical_cpus)
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    if   [ "$n" -ge 120 ]; then model=7380
    elif [ "$n" -ge 90 ];  then model=7360
    elif [ "$n" -ge 64 ];  then model=5380
    # 线程不可用时的兜底（按内存粗略匹配）
    elif [ "$mem_gb" -ge 800 ]; then model=7380
    elif [ "$mem_gb" -ge 450 ]; then model=7360
    else model=5380; fi
    echo "检测到机型 $model（仅用于报告标注与交叉校验）"
fi
```

注意：`n>=64` 归为 5380（5380 双路=64 线程）；若未来出现 7360 单路（48 线程）场景，`n>=90/64` 的分界仍合理。

### Task 2：验证（桩模拟）

- 5380+994G：n=64 → 5380，无 50% 误报警 ✓（本次缺陷场景）
- 7380：n=128 → 7380 ✓
- 7360：n=96 → 7360 ✓
- 线程失败 n=0 + mem=994 → 7380（兜底）✓
- 线程失败 n=0 + mem=400 → 5380 ✓
- 保持：显式 --model 不变、三种机型 case 校验不变

用临时桩模拟（lscpu 桩）执行 start 命令，观察输出。

### Task 3：文档同步

- [README.md L259](../../offline-stress-pkg/README.md)：补充 auto 判定以逻辑线程为主的说明
- [operation-manual.md L395-434](../../offline-stress-pkg/operation-manual.md)：--model 说明同步
- docs/命令执行逻辑.md：若引用 L74-86 行号则同步

## 验证基准

- bash -n stress-lib-commands.sh
- 桩模拟 5 个用例输出与预期一致
- 回归：现有全模式（all/full/hdd/mem/cpu）行为不变

## 约束

- 不 git commit/add/stash
- 不改变机型以外的任何逻辑；不引入新依赖
- 文档同步不扩大范围
