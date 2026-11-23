# 计划：CPU 型号智能识别（从 CPU 信息动态提取，不再硬编码白名单）

- 日期：2026-11-21
- 版本：v1
- 状态：待执行

## 背景

当前 `--model` 只有三种取值：5380 / 7360 / 7380，白名单硬编码在 [stress-lib-commands.sh L87-89](../../offline-stress-pkg/stress-lib-commands.sh)（`case "$model" in 5380|7380|7360)`）与 [stress-lib-common.sh L123-125](../../offline-stress-pkg/stress-lib-common.sh)（`nominal_threads`）。**换新型号（如 9800）会直接报错退出，无法识别**。

但 CPU 型号信息本可从 `lscpu "Model name"` / `/proc/cpuinfo "model name"` 动态读取（如 `Hygon C86-3G 5380 16-core Processor`），参数推导（cpu_workers_auto / 内存推导）已经全部基于实测、与型号无关。用户要求：**智能识别 CPU 型号**。

## 目标

- 新增 `detect_cpu_model()`：从 lscpu/cpuinfo 提取型号数字（如 5380/7380/9800），失败返回空。
- `--model auto` 优先用识别到的型号；识别失败才回退逻辑线程分界。
- `--model <任意数字型号>` 显式传入不再被白名单拒绝（校验放宽为数字型号）。
- `nominal_threads` 增加识别型号→标称线程映射的**扩展点**，未知型号返回空（跳过交叉校验，不影响参数）。

## 改动清单

### Task 1：stress-lib-common.sh 新增/修改

1. 新增 `detect_cpu_model()`：

```bash
# 从 lscpu/CPUINFO 提取 CPU 型号数字（Hygon C86-3G 5380 → "5380"）；失败输出空串
detect_cpu_model() {
    local s=""
    s=$("$LSCPU_BIN" 2>/dev/null | grep -iE "Model name|型号名称" | head -1)
    [ -z "$s" ] && s=$(grep -iE "model name" "$CPUINFO" 2>/dev/null | head -1)
    echo "$s" | sed -nE 's/.*C86-3G[[:space:]]+([0-9]+).*/\1/p' | head -1
}
```

（sed 提取 `C86-3G` 后的数字串；兼容中英文 lscpu 输出。实际正则以可用性为准，由实现者按测试调整。）

2. `nominal_threads()`：把 `case` 映射表改为**可扩展**——新增已知型号则追加条目；未知型号返回空（现有 `*) echo ""` 已覆盖，仅需确保 auto 场景用 detect 到的型号传入）。

### Task 2：stress-lib-commands.sh 修改

1. **auto 分支**（L74-86）：优先 `detect_cpu_model`：

```bash
if [ "$model" = "auto" ]; then
    local detected mem_gb n
    detected=$(detect_cpu_model)
    if [ -n "$detected" ]; then
        model="$detected"     # 智能识别优先
    else
        mem_gb=$(awk ...); n=$(logical_cpus) ... # 现有线程分界兜底
    fi
    echo "检测到机型 $model（仅用于报告标注与交叉校验）"
fi
```

2. **case 白名单**（L87-89）：`5380|7380|7360` 放宽为数字型号：

```bash
case "$model" in
    [0-9][0-9][0-9][0-9]) ;;
    *) echo "未知机型：$model（应为四位数字型号，如 5380|7380|7360，或 auto）"; exit 1 ;;
esac
```

3. **check_model_threads 调用**（L99）：auto 识别到型号时照常调用（nominal_threads 未知→空→跳过校验，不误报警）。

### Task 3：验证（桩模拟）

- `bash -n` 两脚本通过。
- detect_cpu_model 桩：lscpu 输出 `Model name: Hygon C86-3G 5380 16-core Processor` → 5380；`C86-3G 9800 ...` → 9800；无 lscpu/无匹配 → 空。
- auto 分支桩：
  - detect=5380（实际 lscpu 5380 16-core）→ model=5380，**不触发 50% 报警**（5380 标称 64 = 实测 64）✓
  - detect=9800 + 实测 128 线程 → model=9800，nominal_threads(9800)=空 → 跳过校验，不报警 ✓
  - detect 失败 + n=64 → 回退 5380 ✓
  - detect 失败 + n=128 → 回退 7380 ✓
- 显式 `--model 9800` → 不再报"未知机型"，正常启动 ✓
- 回归：`--model 5380`/`7380`/`7360`、auto（7380 机器）行为不变。

### Task 4：文档同步（不扩大范围）

- README.md L259 附近：`--model` 说明改为"支持任意四位数字型号，auto 从 CPU 信息智能识别"
- operation-manual.md L395-434（--model 段）
- docs/命令执行逻辑.md：auto 判定/型号校验段落同步

## 验证基准

- bash -n 通过
- 桩模拟各用例输出与预期一致
- 回归：all/full/hdd/mem 模式、参数推导不受影响

## 约束

- 不 git commit/add/stash
- 只改型号识别与校验；不动 CPU/内存参数推导、check_model_threads 主体
- 文档只同步上述 3 处；不做额外重构
