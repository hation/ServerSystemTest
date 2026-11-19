#!/bin/bash
# stress-test.sh —— 压测主控脚本（Kylin V10 SP3，三类机型 CPU/内存/硬盘压测）
# 用法：
#   bash stress-test.sh start <cpu|mem|hdd|combo> [--model 5380|7380|7360|auto] [--timeout 10h] \
#       [--cpu N] [--vm N] [--vm-bytes X] [--hdd-bytes X] [--dirs "d1 d2"] [--sysdisk] [--sysdisk-only] \
#       [--peer-disks N]
#   说明：hdd 模式无 /mnt/HDD* 挂载点时加 --sysdisk 可仅压系统盘；--sysdisk-only 无论是否有数据盘都只压系统盘；
#         combo 无数据盘时降级为 CPU/内存（或配合 --sysdisk 压系统盘）；
#         combo/mem 的 --peer-disks N 只声明对端并发 hdd 流数（参与内存预留），不启动 hdd 进程；
#         出现该参数即不再自动扫描 /mnt/HDD*（仅显式 --dirs 才在 combo 内启动 hdd），0 表示纯 CPU+内存。
#   bash stress-test.sh status
#   bash stress-test.sh stop
#   bash stress-test.sh review [--dir <结果目录>]
# 环境变量（测试接缝）：
#   STRESS_TEST_ROOT 结果根目录（默认 /root/stress-test）
#   MONITOR_INTERVAL 监控间隔秒（默认 30）
#   FINDMNT_BIN      挂载点设备解析命令（默认 findmnt）
#   LSBLK_BIN        设备名解析命令（默认 lsblk，用于追加 KNAME 归因）
#   CPU_MAX_PCT      CPU worker 兜底百分比（物理核识别失败时按 nproc × 78%，默认 78）
#   NPROC_BIN        逻辑线程数取值命令（默认 nproc）
#   LSCPU_BIN        物理核探测命令（默认 lscpu，-p=Core,Socket 去重）
#   CPUINFO          物理核兜底探测文件（默认 /proc/cpuinfo）
#   MEM_TARGET_PCT   内存兜底目标（MemTotal 的百分比，默认 82，仅混合/未探测容量时使用）
#   MEM_MAX_PCT      模块总容量分配上限（百分比，默认 88）
#   MEM_TOTAL_MAX_PCT MemTotal 分配上限（百分比，默认 92）
#   MEMINFO_FILE     MemTotal 取值文件（默认 /proc/meminfo）
#   DMI_BIN          DIMM 根数探测命令（默认 dmidecode）
#   EDAC_ROOT        DIMM 根数第二探测来源（默认 /sys/devices/system/edac/mc）
# 退出码：0=正常（含无运行任务）；1=用法错误/前置条件不满足
# 说明：全程不 set -e；压测与监控均 nohup 后台运行、全部落盘，可脱离 ssh 会话。
#       CPU worker 按逻辑线程（物理核 × 每核线程数，SMT 探测；未知默认开）× 25/32 推导。

STRESS_TEST_ROOT="${STRESS_TEST_ROOT:-/root/stress-test}"
MONITOR_INTERVAL="${MONITOR_INTERVAL:-30}"
DF_BIN="${DF_BIN:-df}"
DMESG_BIN="${DMESG_BIN:-dmesg}"
FINDMNT_BIN="${FINDMNT_BIN:-findmnt}"
LSBLK_BIN="${LSBLK_BIN:-lsblk}"
# dmesg 内核 I/O 错误正则（大小写不敏感；口径见设计 6.3）
DMESG_IO_RE='EXT4-fs error|EXT4-fs .*error|I/O error|Buffer I/O error|blk_update_request|critical medium error|ata[0-9.]+: .*(failed|error)|nvme[0-9]+.*(error|timeout|reset)|reset .*failed'
# dmesg OOM 正则（沿用既有口径）
DMESG_OOM_RE='oom|out of memory|killed process|Killed'
MEM_MAX_PCT="${MEM_MAX_PCT:-88}"          # 模块总容量分配上限（百分比），案例 87.5% 需落在 88% 内
MEM_TARGET_PCT="${MEM_TARGET_PCT:-82}"    # 内存兜底目标（MemTotal 的百分比），仅混合/未探测容量时使用
MEM_TOTAL_MAX_PCT="${MEM_TOTAL_MAX_PCT:-92}"  # MemTotal 分配上限（百分比）
MEMINFO_FILE="${MEMINFO_FILE:-/proc/meminfo}"
CPU_MAX_PCT="${CPU_MAX_PCT:-78}"          # 物理核识别失败时的 CPU 兜底百分比（逻辑线程数的百分比）
NPROC_BIN="${NPROC_BIN:-nproc}"           # 逻辑线程数取值入口（测试接缝）
LSCPU_BIN="${LSCPU_BIN:-lscpu}"           # 物理核探测入口（测试接缝）
CPUINFO="${CPUINFO:-/proc/cpuinfo}"       # 物理核兜底探测文件（测试接缝）
# 磁盘页缓存/脏页预留：D × hdd-bytes × 1.2 + 8G（D 为数据盘目录数 + --sysdisk）
DISK_CACHE_FACTOR_PCT="${DISK_CACHE_FACTOR_PCT:-120}"   # 1.2 倍，整数百分比用于 bash 运算
DISK_CACHE_MIN_G="${DISK_CACHE_MIN_G:-8}"
DMI_BIN="${DMI_BIN:-dmidecode}"           # DIMM 根数探测入口（测试接缝）
EDAC_ROOT="${EDAC_ROOT:-/sys/devices/system/edac/mc}"  # DIMM 根数第二探测来源（测试接缝）
SCRIPT="$(readlink -f "$0" 2>/dev/null || echo "$0")"

usage() {
    cat <<'EOF'
用法:
  bash stress-test.sh start <cpu|mem|hdd|combo> [--model 5380|7380|7360|auto] [--timeout 10h] \
      [--cpu N] [--vm N] [--vm-bytes X] [--hdd-bytes X] [--dirs "d1 d2"] [--sysdisk] [--sysdisk-only] \
      [--peer-disks N]
  bash stress-test.sh status
  bash stress-test.sh stop
  bash stress-test.sh review [--dir <结果目录>]
  bash stress-test.sh snapshot <结果目录>   # 立即抓取一次运行时证据快照

推导规则（不传对应参数时自动生效）:
  CPU worker 数 = max(1, round(逻辑线程数 × 25/32))，逻辑线程 = 物理核 × 每核线程数（SMT 探测，未知默认开）；
                  SMT 关闭（每核1线程）时逻辑线程减半，worker 相应减半（5380→25、7360→38、7380→50）；
                  物理核识别失败回退 nproc × 78%（环境变量 CPU_MAX_PCT）
  内存单 worker = 单条容量 − max(6G, 单条容量/8)，VM worker = DIMM 根数
  内存上限 = min(模块总容量 × 88%, MemTotal × 92%,
                 MemTotal − (盘数 × hdd-bytes × 1.2 + 8G))，超限逐 GiB 下调单 worker
  混合容量 / EDAC 无容量 / 显式 --vm ≠ DIMM 数 → MemTotal × 82% 均分（上限 92%）
  mem / combo 固定追加 --vm-keep（内存常驻）；hdd 每块数据盘 1 个进程
  内存条根数 = --vm（默认按 DIMM 自动探测，等于实际内存条根数；探测失败时可手动 --vm N）
  --peer-disks N（仅 combo/mem）：对端并发 hdd 流数，cap_disk 按 max(实际盘数, N) 预留；
                         只影响内存推导与展示，不启动 hdd 进程；出现即不再自动扫描 /mnt/HDD*

示例:
  bash stress-test.sh start cpu                # 按逻辑线程推导跑 CPU 压测（默认 10h）
  bash stress-test.sh start mem                # 按实测 MemTotal 与内存条根数推导跑内存压测（默认 10h）
  bash stress-test.sh start hdd --dirs "/mnt/HDD01 /mnt/HDD02"
  bash stress-test.sh start hdd --sysdisk       # 仅压系统盘（无数据盘时）
  bash stress-test.sh start hdd --sysdisk-only  # 仅压系统盘（无论是否有数据盘）
  bash stress-test.sh start combo --dirs "/mnt/HDD01 /mnt/HDD02" --sysdisk  # CPU+内存+每盘 hdd+系统盘
  bash stress-test.sh review --dir /root/stress-test/20261113-143000-cpu
EOF
}

# 在变量区之后、分发之前
SCRIPT_DIR="$(dirname "$SCRIPT")"
for _lib in stress-lib-common stress-lib-devices stress-lib-snapshot stress-lib-monitor stress-lib-commands; do
    if [ -f "$SCRIPT_DIR/$_lib.sh" ]; then
        # shellcheck disable=SC1090
        source "$SCRIPT_DIR/$_lib.sh"
    else
        echo "缺少模块文件：$SCRIPT_DIR/$_lib.sh"; exit 1
    fi
done

# ---------- 子命令分发 ----------

CMD="${1:-}"
shift || true
case "$CMD" in
    start)         cmd_start "$@" ;;
    status)        cmd_status ;;
    stop)          cmd_stop ;;
    review)        cmd_review "$@" ;;
    snapshot)      cmd_snapshot "$@" ;;
    monitor-loop)  cmd_monitor_loop "$@" ;;
    *) usage; exit 1 ;;
esac
