#!/bin/bash
# oneclick.sh —— 一键压测入口（菜单/子命令）
# 用法：bash oneclick.sh --help
# 说明：启动编排（参数/菜单、前置检查、自动挂载、任务计划、终端窗口或后台启动、
#       内部子命令 __task、就绪握手、失败即停）+ 等待全部结束 + 自动逐个复盘 + 汇总。
#       --no-hdd：仅 all 模式生效，排除所有硬盘（数据盘+系统盘），仅测 CPU+内存（COMBO peer=0），
#       跳过自动挂载且与 --rebuild 互斥。
#       status/review 子命令均基于最近一次批次目录（$STRESS_TEST_ROOT/oneclick-*）。
PKG_DIR="$(cd "$(dirname "$0")" && pwd)"
STRESS_TEST_ROOT="${STRESS_TEST_ROOT:-/root/stress-test}"
ST="${ONECLICK_STRESS_TEST_SH:-$PKG_DIR/stress-test.sh}"
DM="${ONECLICK_DISK_MOUNT_SH:-$PKG_DIR/disk-mount.sh}"
# 相对路径规范化为绝对路径（存在性仍由 precheck 负责检查）
case "$ST" in
    /*) ;;
    *) _abs_dir=$(cd "$(dirname "$ST")" 2>/dev/null && pwd) && ST="$_abs_dir/$(basename "$ST")" ;;
esac
case "$DM" in
    /*) ;;
    *) _abs_dir=$(cd "$(dirname "$DM")" 2>/dev/null && pwd) && DM="$_abs_dir/$(basename "$DM")" ;;
esac
unset _abs_dir
POLL_INTERVAL="${ONECLICK_POLL_INTERVAL:-30}"
# 轮询间隔只接受 >=1 的整数，非法值回落 30（避免 sleep 报错后空转）
case "$POLL_INTERVAL" in
    ''|*[!0-9]*) POLL_INTERVAL=30 ;;
esac
[ "$POLL_INTERVAL" -ge 1 ] || POLL_INTERVAL=30
READY_TIMEOUT="${ONECLICK_READY_TIMEOUT:-180}"
ONECLICK_SKIP_ROOT_CHECK="${ONECLICK_SKIP_ROOT_CHECK:-0}"
# 命令显示开关：默认打印；ONECLICK_SHOW_CMD=0 或 --quiet 关闭（不影响落盘）
SHOW_CMD="${ONECLICK_SHOW_CMD:-1}"
[ "$SHOW_CMD" = "0" ] || SHOW_CMD=1
DEFAULT_TIMEOUT="10h"

TIMEOUT="$DEFAULT_TIMEOUT"
BATCH=""
START_TIME=""
MODE=""
TERM_KIND=""
ABORTED=0
# 启动失败标记：数据盘/系统盘启动失败时置 1（COMBO 失败另由 ABORTED 中止后续），批次最终退出 1
START_FAILED=0
LAST_TASK_CMD=""
# 数据盘重建开关：默认 0（复用已有文件系统）；--rebuild 或菜单输入 y 才置 1
REBUILD=0
# 排除硬盘开关：仅 all 模式生效；--no-hdd 置 1（任务计划只写 COMBO peer=0，跳过数据盘/系统盘任务）
NO_HDD=0
# 中高强度开关：--high 置 1（一键中高强度整机压测，等价 full；与 --no-hdd 互斥）
HIGH=0
# 自动挂载退出码：all/hdd 记录 disk-mount.sh 的结果，非 0 表示存在跳过/失败盘，批次最终退出 1
MOUNT_RC=0
# 整机压测（full）中高强度参数：默认按"朋友规则"推导（CPU≈round(逻辑线程×70%)、VM=DIMM 根数、
# vm-bytes=脚本单根推导公式 单条容量−max(单条/8,6G)，推导值作为显式参数写入 COMBO 计划、不裁剪），
# 可用环境变量 FULL_CPU / FULL_VM / FULL_VMBYTES 显式覆盖（换机调参，显式优先）
FULL_CPU="${FULL_CPU:-}"
FULL_VM="${FULL_VM:-}"
FULL_VMBYTES="${FULL_VMBYTES:-}"
# 硬件探测接缝（与 stress-test.sh 同默认值）：full 朋友规则推导复用 stress-lib-common.sh 探测函数
LSCPU_BIN="${LSCPU_BIN:-lscpu}"
NPROC_BIN="${NPROC_BIN:-nproc}"
CPUINFO="${CPUINFO:-/proc/cpuinfo}"
DMI_BIN="${DMI_BIN:-dmidecode}"
EDAC_ROOT="${EDAC_ROOT:-/sys/devices/system/edac/mc}"

# stress-lib-common 提供 full 朋友规则推导所需的硬件探测函数
# （logical_cpus / physical_cores / smt_tpc / dimm_count_auto / dimm_cap_gib_uniform）
for _lib in stress-lib-common oneclick-lib-basic oneclick-lib-run; do
    if [ -f "$PKG_DIR/$_lib.sh" ]; then
        source "$PKG_DIR/$_lib.sh"
    else
        echo "缺少模块文件：$PKG_DIR/$_lib.sh"; exit 1
    fi
done

# ---------- full 朋友规则推导 ----------

# 朋友规则推导 full 默认参数（中高强度）：CPU=round(逻辑线程×70%)、VM=DIMM 根数、
# vm-bytes=脚本单根推导公式 单条容量−max(单条/8,6G)（如 32G 条→26G、64G 条→56G）。
# 成功设置 FULL_CPU/FULL_VM/FULL_VMBYTES 并返回 0；探测失败返回 1（不设置变量）
full_params_friend() {
    local cores tpc logical cpu vm per reserve per_g
    cores=$(physical_cores)
    if [ "$cores" -ge 1 ]; then
        tpc=$(smt_tpc); [ -z "$tpc" ] && tpc=2
        logical=$(( cores * tpc ))
        cpu=$(( (logical * 70 + 50) / 100 ))     # round(逻辑线程×70%)
    else
        logical=$(logical_cpus)
        case "$logical" in ''|*[!0-9]*) return 1 ;; esac
        [ "$logical" -ge 1 ] || return 1
        cpu=$(( (logical * 70 + 50) / 100 ))     # nproc 兜底
    fi
    [ "$cpu" -lt 1 ] && cpu=1
    vm=0
    dimm_count_auto >/dev/null                    # 设置 DIMM_COUNT/DIMM_CAPS 等全局
    vm=${DIMM_COUNT:-0}
    [ "$vm" -ge 1 ] || return 1
    per=$(dimm_cap_gib_uniform "$DIMM_CAPS" 2>/dev/null)   # 单条容量 GiB
    case "$per" in ''|*[!0-9]*) return 1 ;; esac
    [ "$per" -ge 1 ] || return 1
    reserve=$(( per / 8 )); [ "$reserve" -lt 6 ] && reserve=6   # 脚本公式 max(单条/8, 6G)
    per_g=$(( per - reserve )); [ "$per_g" -lt 1 ] && per_g=1
    FULL_CPU="$cpu"; FULL_VM="$vm"; FULL_VMBYTES="${per_g}G"
    return 0
}

# ---------- 菜单 ----------

show_menu() {
    cat <<EOF
==== 一键压测 ====
  1) 求稳强度压测（CPU+内存组合 + 每盘独立 + 系统盘；参数自动推导，保守）
  2) 中高强度整机压测（同上任务构成；参数按朋友规则推导，FULL_* 显式设置可覆盖）
  3) 测 CPU+内存（排除硬盘）
  4) 只测硬盘（数据盘）
  5) 只测系统盘
  6) 只测 CPU
  7) 只测内存
  8) 查看状态
  9) 生成复盘
  0) 退出
当前超时：$TIMEOUT（可用 --timeout 覆盖）
EOF
}

# 菜单 1/3 启动前询问一次是否重建数据盘；默认 N（仅 y/Y 视为确认）
ask_rebuild() {
    local ans=""
    printf '是否重新分区并格式化数据盘？(y/N)：'
    if ! IFS= read -r ans; then
        # 读取失败（EOF）时补换行，避免后续提示与询问挤在同一行
        echo
        ans=""
    fi
    case "$ans" in
        y|Y) REBUILD=1 ;;
        *) REBUILD=0 ;;
    esac
}

menu_loop() {
    local choice
    while :; do
        show_menu
        printf '请选择（0-9）：'
        if ! IFS= read -r choice; then
            echo
            exit 0
        fi
        case "$choice" in
            # CLI 已带 --rebuild 时不再询问，直接按重建语义执行
            # 项 1/2/4（all/full/hdd）前显式复位 NO_HDD=0，防上一轮选 3（NO_HDD=1）串味
            1) NO_HDD=0; if [ "$REBUILD" = "0" ]; then ask_rebuild; fi; run_mode all ;;
            2) NO_HDD=0; if [ "$REBUILD" = "0" ]; then ask_rebuild; fi; run_mode full ;;
            3) NO_HDD=1; REBUILD=0; run_mode all ;;
            4) NO_HDD=0; if [ "$REBUILD" = "0" ]; then ask_rebuild; fi; run_mode hdd ;;
            5) run_mode sysdisk ;; 6) run_mode cpu ;; 7) run_mode mem ;; 8) cmd_status ;; 9) cmd_review ;;
            0) exit 0 ;;
            *) echo "无效选择：$choice（请输入 0-9）" ;;
        esac
    done
}

# ---------- 参数解析与分发 ----------

main() {
    if [ "${1:-}" = "__task" ]; then
        shift
        if [ $# -lt 4 ]; then
            echo "内部子命令 __task 参数不足（需要 <batch> <id> <timeout> <type>）"
            exit 1
        fi
        cmd_task "$@"
        exit 0
    fi

    local mode=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            --quiet)
                SHOW_CMD=0
                shift
                ;;
            --rebuild)
                REBUILD=1
                shift
                ;;
            --no-hdd)
                NO_HDD=1
                shift
                ;;
            --high)
                HIGH=1
                shift
                ;;
            --timeout)
                if [ $# -lt 2 ]; then
                    echo "缺少 --timeout 取值"
                    exit 1
                fi
                TIMEOUT="$2"
                shift 2
                ;;
            --timeout=*)
                TIMEOUT="${1#*=}"
                shift
                ;;
            all|hdd|sysdisk|cpu|mem|full)
                mode="$1"
                shift
                ;;
            status)
                mode=status
                shift
                ;;
            review)
                mode=review
                shift
                ;;
            *)
                echo "未知参数：$1"
                usage
                exit 1
                ;;
        esac
    done

    # --high 与 --no-hdd 互斥（中高强度必含硬盘）：最先校验，保证任何组合下都给出明确错误
    if [ "$HIGH" -eq 1 ] && [ "$NO_HDD" -eq 1 ]; then
        echo "--high 与 --no-hdd 不能同时使用（中高强度必须含硬盘）"
        exit 1
    fi
    if [ "$NO_HDD" -eq 1 ] && [ "$mode" != "all" ]; then
        echo "--no-hdd 仅支持 all 模式"
        exit 1
    fi
    if [ "$NO_HDD" -eq 1 ] && [ "$REBUILD" -eq 1 ]; then
        echo "--rebuild 与 --no-hdd 不能同时使用（--no-hdd 不涉及任何硬盘）"
        exit 1
    fi

    if ! [[ "$TIMEOUT" =~ ^[0-9]+[dhms]?$ ]]; then
        echo "--timeout 取值非法：$TIMEOUT（应形如 10h / 30m / 8h）"
        exit 1
    fi

    # --high 归一：仅整机模式（all/full）生效；无模式时一键直达中高 full（跳过菜单）；其它模式提示忽略
    if [ "$HIGH" -eq 1 ]; then
        case "$mode" in
            ""|all|full) mode=full ;;
            status|review) ;;
            *)
                echo "提示：--high 仅对整机（all/full）生效，本次忽略"
                HIGH=0
                ;;
        esac
    fi

    case "$mode" in
        "") menu_loop ;;
        status) cmd_status ;;
        review) cmd_review ;;
        all|hdd|sysdisk|cpu|mem|full) run_mode "$mode" ;;
    esac
}

main "$@"
