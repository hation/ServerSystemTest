# 计划：CPU 型号识别扩展支持 AMD/Intel（多品牌通用）

- 日期：2026-11-21
- 版本：v1
- 状态：待执行
- 前置：2026-11-21-smart-cpu-model-detect（海光智能识别已落地，本计划在其上扩展）

## 背景

上一计划已实现 `detect_cpu_model()`（仅匹配海光 `C86-3G` 前缀）与四位数字白名单、auto 交叉校验修正。用户确认需扩展支持 **AMD EPYC / Intel Xeon** 等其它品牌：目前 AMD/Intel 机器 auto 识别返回空 → 回退逻辑线程分界，导致机型标注不准（如 AMD 128 线程被标成 7380）。参数推导始终按实测、不受影响，本次只扩展**品牌识别与标称映射**。

## 目标

- `detect_cpu_model()` 支持多品牌：海光（C86-3G）、AMD（EPYC 系列）、Intel（Xeon 系列）——从型号字符串提取品牌代号 + 型号数字（如 `AMD EPYC 7763` → `EPYC 7763` 或 `AMD-7763` 等统一格式）。
- 标称线程映射表 `nominal_threads()` 按品牌补充常见型号（AMD EPYC 7xxx/9xxx 各档、Intel Xeon 各代典型线程数），未知型号返回空（跳过校验，不误报）。
- auto 分界仍以逻辑线程为主，识别结果做交叉校验修正；标注统一可读格式。
- 文档同步。

## 改动清单

### Task 1：stress-lib-common.sh

1. `detect_cpu_model()` 扩展为多品牌：

```bash
# 多品牌 CPU 型号识别：海光 C86-3G、AMD EPYC、Intel Xeon（含中文输出兼容）
# 输出统一格式：如 "5380" / "EPYC-7763" / "Xeon-6338"；无法识别输出空串
detect_cpu_model() {
    local s=""
    s=$("$LSCPU_BIN" 2>/dev/null | grep -iE "Model name|型号名称" | head -1)
    [ -z "$s" ] && s=$(grep -iE "model name" "$CPUINFO" 2>/dev/null | head -1)
    case "$s" in
        *[Cc]86-3[Gg]*) echo "$s" | sed -nE 's/.*[Cc]86-3[Gg][[:space:]]+([0-9]+).*/\1/p' | head -1 ;;
        *[Ee][Pp][Yy][Cc]*) echo "$s" | sed -nE 's/.*(EPYC[[:space:]]*[0-9]+).*/\1/p' | head -1 | tr -d ' ' ;;
        *[Xx][Ee][Oo][Nn]*) echo "$s" | sed -nE 's/.*(Xeon[[:space:]]*[^0-9]*[0-9]+).*/\1/p' | head -1 ;;
        *) echo "" ;;
    esac
}
```

（实际正则由实现者按测试调整，以能提取到品牌+数字为准；输出格式统一、可读。）

2. `nominal_threads()` 扩展：已知品牌型号映射（AMD EPYC 7763→128、Intel Xeon 6338→64 等典型），未知返回空。

### Task 2：stress-lib-commands.sh

- auto 分支与 case 白名单适配：识别结果可能含非数字（`EPYC-7763`），白名单从 `[0-9]{4}` 放宽为"非空且非纯空"（或按品牌格式校验）；交叉校验修正逻辑对未知标称型号跳过、对已知按映射校验。
- 注意：`nominal_threads` 需要能对 `EPYC-7763` / `Xeon-6338` 查映射。

### Task 3：桩模拟验证

- AMD EPYC 7763（128 线程）→ 识别 `EPYC-7763`，标称 128 = 实测 → 标注正确、无报警。
- Intel Xeon 6338（64 线程）→ 识别 `Xeon-6338`，标称 64 = 实测 → 正确。
- AMD 未知型号（128 线程）→ 识别成功但标称未知 → 跳过校验、标注品牌型号、参数按实测。
- 海光回归：5380/7380/9800 行为不变。
- 识别失败（无品牌匹配）→ 回退逻辑线程分界，标注"未知型号"而非猜 7380。
- 参数推导不受影响：全部按实测逻辑线程。

### Task 4：文档同步

- README.md / operation-manual.md / docs/命令执行逻辑.md：--model 说明扩展为多品牌。

## 验证基准

- bash -n 通过
- 桩模拟各用例输出与预期一致
- 回归：海光场景、显式 --model、all/full 参数推导不变

## 约束

- 不 git commit/add/stash
- 只改型号识别与标称映射；不动 cpu_workers_auto / 内存推导主体
- 文档只同步 3 处；不做额外重构
