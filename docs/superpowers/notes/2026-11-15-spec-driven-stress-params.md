# 压测参数按实测规格推导 · 交付记录

- 日期：2026-11-15
- 计划：`docs/superpowers/plans/2026-11-15-spec-driven-stress-params.md`
- 设计：`docs/superpowers/specs/2026-11-15-spec-driven-stress-params-design.md`
- 执行方式：Subagent-driven development（每任务独立实现 + 独立评审；末尾整支复查 + 一次修复波）
- 提交状态：按用户要求**未提交**，改动留在工作区（分支 `fix/stress-memory-guard`）

## 1. 做了什么

把 `stress-test.sh` 的 CPU / 内存参数从“按机型查表”改为“按实测规格推导”：

| 项 | 规则 |
|---|---|
| CPU worker | `max(1, floor(nproc × 86%))`，显式 `--cpu` 优先 |
| 内存总量 | `MemTotal × 82%`，硬上限 `MemTotal × 85%` |
| 单 worker | `round(总量 / 根数) GiB`，不小于 1G |
| `--vm` | 等于实际内存条根数（dmidecode → EDAC；双源失败且未显式给 `--vm` 则退出码 1） |
| 显式参数 | `--vm` / `--vm-bytes` 不被静默改写；`--vm-bytes` 超 85% 只告警 |

机型（5380=64 / 7360=96 / 7380=128 线程）只做交叉校验，偏差 >10% 提示“疑似单路”，**不参与分配**。

### 改动的文件

- `offline-stress-pkg/stress-test.sh`：新增 `logical_cpus` / `cpu_workers_auto` / `check_model_threads` / `dimm_count_*` / `mem_plan`；删除三机型预设查表；run-config 增 `CPU 逻辑线程`、`CPU worker 数`、`内存条根数（来源）`、`单根容量`、`内存目标`、`内存分配上限`；info-before 增 dmidecode / numactl 两段；启动前打印最终命令与推导依据；`--vm` 前导零归一化为十进制；显式 `--vm-bytes` 无法解析时中文报错退出；双源探测失败时按本机 MemTotal 直接给出可复制执行的建议命令（16 worker 平分 82%，或只填实际根数）。
- `offline-stress-pkg/operation-manual.md`：删除机型预设表，改为推导规则 + 四规格回算表 + 边界说明。
- `offline-stress-pkg/README.md`：默认命令去掉 `--model` 依赖，说明其仅用于标注与交叉校验。
- `offline-stress-pkg.zip`：按目录内容重打（正斜杠条目，顶层保留 `offline-stress-pkg/`）。
- `offline-stress-pkg/rpms/dmidecode-3.2-10.el8.x86_64.rpm`：新增（CentOS 8.5 vault，阿里云与清华两镜像 SHA256 一致：`CD2F140B…DA62C6`）；`install.sh` 改为按清单安装 stress + dmidecode（逐个 SHA256 校验、已装跳过），`verify.sh` 增 dmidecode 可用性检查（缺失只 WARN）。EDAC 是内核 sysfs 接口，无法打包。
- `.superpowers/sdd/2026-11-15-spec-driven-stress-params/tests/`：`lib.sh`、`t1_cpu.sh`、`t2_dimm_mem.sh`、`t3_edge_combo.sh`、`run-all.sh`（离线假件驱动真实脚本）。

## 2. 现场规格回算

| MemTotal | 根数 | 单 worker | 实际下发 | 占物理内存 |
|---|---|---|---|---|
| 502.5 GiB | 16 | 26G | 416G | 82.8% |
| 754.5 GiB | 12 | 52G | 624G | 82.7% |
| 994.7 GiB | 16 | 51G | 816G | 82.0% |
| 1120.7 GiB | 18 | 51G | 918G | 81.9% |
| 384 GiB | 12 | 26G | 312G | 81.3% |
| 512 GiB | 16 | 26G | 416G | 81.3% |

对比改造前统一下发 `16×54G = 864G`：502.5 GiB 机器为 172%（必然 OOM），754.5 GiB 为 114%（打满 Swap）。

## 3. 验证

```
bash -n offline-stress-pkg/stress-test.sh     # 通过
bash .superpowers/sdd/2026-11-15-spec-driven-stress-params/tests/run-all.sh
# t1 ALL PASS（19 项）
# t2 ALL PASS（83 项）
# t3 ALL PASS（27 项）
# 全部测试: ALL PASS
```

测试覆盖：CPU 110/82/55 与显式覆盖；六种现场规格；dmidecode/EDAC 回退与双源失败中止；`Size: No Module Installed` / `Installed Size:` 过滤；混合容量；显式 `--vm`/`--vm-bytes`（含超限告警、非法值、前导零）；`--vm ""` 空值回退；根数 >256；MemTotal 不可读的两条分支；单 worker <1G；combo 无数据盘；hdd 空 `--dirs`；用法文案。

Zip 校验：13 个条目，含 `offline-stress-pkg/stress-test.sh`、`operation-manual.md`、`rpms/stress-1.0.4-24.el8.x86_64.rpm`，包内校验和与工作区一致。

## 4. 现场建议

```bash
bash stress-test.sh start mem --timeout 60s   # 先短跑一次，核对 run-config 的“内存条根数/来源/内存目标”
```

若 `dmidecode` 不可用，脚本会回退 EDAC；两者都不可用时按提示手动指定：

```bash
bash stress-test.sh start mem --vm 16
```

## 5. 已知遗留（不影响交付）

1. 设计文档 6.4 仍写“四舍五入到 1G，保证不低于 82%”；实际极少数规格（如 502.5GiB/10 根）为 81.6%，手册已改为“通常落在 81–83%”。设计文档未改（属已批准文本，交由用户决定是否修订）。
2. 显式 `--vm-bytes 010G` 内部按 10G 计算，但下发给 stress 的仍是字面量 `010G`；正常写法（`51G`）不受影响。
3. 自动推导路径下，原 85% 裁剪分支 A/B 已不可达（保留作兜底），其中仍保留“内存预设”旧措辞。
4. 测试夹具在 t2/t3 有重复（未下沉 `lib.sh`）；t1 的假 `stress --version` 会占用 5 秒。
5. `operation-manual.md` 中 `info-before.txt` / `operations.log` 的字段说明未同步新增的 dmidecode/numactl/model-check/mem-plan。
