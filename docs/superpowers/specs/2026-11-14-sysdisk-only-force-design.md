# 仅系统盘压测（强制模式）设计 —— `start hdd --sysdisk-only`

- 日期：2026-11-14
- 状态：待评审
- 修改文件：`offline-stress-pkg/stress-test.sh`
- 背景：上一版实现了"无数据盘时 `start hdd --sysdisk` 自动降级为仅系统盘"，但**有数据盘时仍会同时压数据盘**，不满足"无论是否有数据盘都只压系统盘"。

## 1. 需求

无论机器上是否有 `/mnt/HDD*` 挂载点，都能**只压系统盘**，不启动任何数据盘压测进程。

## 2. 方案

新增参数 `--sysdisk-only`：

```bash
sudo bash stress-test.sh start hdd --sysdisk-only
```

行为：
1. 等价于"`--sysdisk` 开启 + 数据盘目录强制为空"
2. **不扫描 `/mnt/HDD*`**，即使存在也不压
3. 隐式包含 `--sysdisk` 效果（无需重复给 `--sysdisk`；同时给也允许）
4. 仅对 **hdd** 模式生效：
   - `combo --sysdisk-only` → 报错"仅系统盘请用 start hdd --sysdisk-only"并退出 1（combo 语义含 CPU/内存，不适合）
   - `cpu/mem --sysdisk-only` → 提示忽略并退出？按现有 `--sysdisk` 风格：提示"仅 hdd 模式生效"后继续原模式（不启动系统盘压测）
5. 与 `--dirs` 同时出现 → **报错退出 1**（避免用户误以为会压数据盘）
6. 结果目录仍是 `<时间戳>-hdd/`，只含 `stress-SYSDISK.log` / `error-SYSDISK.log` / `stress-SYSDISK.exitcode`

## 3. 校验顺序

1. 参数解析：`--sysdisk-only` → `sysdisk=1; sysdisk_only=1`
2. 模式校验（先于其它校验）：
   - `sysdisk_only=1 && type=combo` → 报错退出
   - `sysdisk_only=1 && type!=hdd`（cpu/mem）→ 提示仅 hdd 生效，按原模式继续（不压盘）
   - `sysdisk_only=1 && dirs_given=1` → 报错退出
3. `sysdisk_only=1` 时跳过数据盘扫描与校验，`dirs=()`
4. 系统盘空间预检、`/stresstest-hdd`、启动、monitor、review 复用现有逻辑

## 4. 文档

- 脚本头部用法注释 + `usage()` 增加 `--sysdisk-only`
- `operation-manual.md` §11 增加用法示例与说明
- `README.md` 如有相关用法处补充（无则不动）

## 5. 测试（stub 化）

1. `start hdd --sysdisk-only`（有 `/mnt/HDD*` 且已挂载）→ 不压数据盘，只启动 1 个系统盘进程
2. `start hdd --sysdisk-only`（无 `/mnt/HDD*`）→ 同上
3. `start hdd --sysdisk-only --dirs "/mnt/HDD01"` → 退出 1，提示冲突
4. `start combo --sysdisk-only` → 退出 1，提示改用 hdd
5. `start cpu --sysdisk-only` → 提示仅 hdd 生效，按 cpu 正常启动
6. `start hdd --sysdisk --dirs ...`（原行为）→ 数据盘 + 系统盘（回归）
7. `start hdd --sysdisk`（无数据盘降级）→ 仅系统盘（回归）
8. `bash -n` 通过

## 6. 非目标

- 不改 combo 降级语义
- 不改系统盘压测内容
- 不新增独立子命令（沿用 `start hdd`）
