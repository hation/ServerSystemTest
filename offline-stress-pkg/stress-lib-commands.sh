# ---------- start ----------

cmd_start() {
    local type="$1"
    shift || true
    [ -n "$type" ] || { usage; exit 1; }
    case "$type" in
        cpu|mem|hdd|combo) ;;
        *) echo "未知压测类型：$type（应为 cpu|mem|hdd|combo）"; usage; exit 1 ;;
    esac

    # 参数解析：--model / --timeout / --cpu / --vm / --vm-bytes / --hdd-bytes / --dirs / --sysdisk / --sysdisk-only / --peer-disks
    local model="auto" timeout="10h" cpu_opt="" vm_opt="" vm_bytes_opt="" hdd_bytes_opt="" dirs_opt="" dirs_given=0 sysdisk=0 sysdisk_only=0
    local peer_disks_opt="" peer_given=0 peer_disks=0
    local bytes_from_preset=1   # 显式 --vm-bytes 置 0，用于内存裁剪分支判定
    while [ $# -gt 0 ]; do
        case "$1" in
            --model|--timeout|--cpu|--vm|--vm-bytes|--hdd-bytes|--dirs|--peer-disks)
                if [ $# -lt 2 ]; then echo "参数 $1 缺少取值"; usage; exit 1; fi
                ;;
        esac
        case "$1" in
            --model)     model="$2";        shift 2 ;;
            --timeout)   timeout="$2";      shift 2 ;;
            --cpu)       cpu_opt="$2";      shift 2 ;;
            --vm)        vm_opt="$2";       shift 2 ;;
            --vm-bytes)  vm_bytes_opt="$2"; bytes_from_preset=0; shift 2 ;;
            --hdd-bytes) hdd_bytes_opt="$2"; shift 2 ;;
            --dirs)      dirs_opt="$2"; dirs_given=1; shift 2 ;;
            --peer-disks) peer_disks_opt="$2"; peer_given=1; shift 2 ;;
            --sysdisk)   sysdisk=1;         shift 1 ;;
            --sysdisk-only) sysdisk=1; sysdisk_only=1; shift 1 ;;
            *) echo "未知参数：$1"; usage; exit 1 ;;
        esac
    done

    # --peer-disks N：非负整数；仅 combo/mem 生效，cpu/hdd 收到时只告警、不改变行为
    if [ "$peer_given" -eq 1 ]; then
        case "$peer_disks_opt" in
            ''|*[!0-9]*) echo "参数 --peer-disks 取值非法：$peer_disks_opt（应为非负整数，如 12 或 0）"; usage; exit 1 ;;
        esac
        peer_disks=$(( 10#$peer_disks_opt ))
        if [ "$type" != "combo" ] && [ "$type" != "mem" ]; then
            echo "提示：--peer-disks 仅对 combo/mem 模式生效，$type 模式忽略该选项"
            peer_given=0
            peer_disks=0
        fi
    fi

    # cpu/mem 模式下 --sysdisk 无效，仅提示（hdd/combo 才生效；--sysdisk-only 在下方单独提示，避免重复）
    if [ "$sysdisk" -eq 1 ] && [ "$sysdisk_only" -ne 1 ] && { [ "$type" = "cpu" ] || [ "$type" = "mem" ]; }; then
        echo "提示：--sysdisk 仅对 hdd/combo 模式生效，cpu/mem 模式忽略该选项"
    fi

    # --sysdisk-only 模式校验（先于机型解析）
    if [ "$sysdisk_only" -eq 1 ]; then
        if [ "$type" = "combo" ]; then
            echo "combo 模式包含 CPU/内存，仅压系统盘请用：bash stress-test.sh start hdd --sysdisk-only"
            exit 1
        fi
        if [ "$type" = "cpu" ] || [ "$type" = "mem" ]; then
            echo "提示：--sysdisk-only 仅对 hdd 模式生效，当前模式忽略该选项"
            sysdisk=0
        elif [ "$dirs_given" -eq 1 ]; then
            echo "--sysdisk-only 与 --dirs 不能同时使用（仅压系统盘时不会压数据盘）"
            exit 1
        fi
    fi

    # 结果根目录（非结果目录，提前创建）：作为 operations.log 的落脚点，
    # 保证机型交叉校验、内存推导等前置步骤的日志都能落盘
    mkdir -p "$STRESS_TEST_ROOT" || { echo "无法创建结果根目录：$STRESS_TEST_ROOT"; exit 1; }

    # 机型解析（缺省 auto）：优先从 CPU 信息智能识别型号（lscpu "Model name" / /proc/cpuinfo "model name"，
    # 多品牌：海光 C86-3G 后型号数字如 5380/9800、AMD EPYC-xxxx、Intel Xeon-xxxx，兼容中英文输出）；
    # 识别失败回退逻辑线程分界（5380=64、7360=96、7380=128，含内存兜底）。
    # 识别结果与实际逻辑线程交叉校验：不一致（偏差>10%）时明确提示"型号识别结果与实测线程不符"；
    # 仅海光四位数字型号标称与实测矛盾时才按实测线程分界修正（AMD/Intel 品牌型号保留品牌标注、不做分界修正，
    # 避免把 EPYC/Xeon 误标成海光档位）；识别来源写入启动日志与 run-config 机型字段，便于复核。
    if [ "$model" = "auto" ]; then
        local detected mem_gb n src
        detected=$(detect_cpu_model)
        if [ -n "$detected" ]; then
            model="$detected"
            src="智能识别 CPU 信息"
            n=$(logical_cpus)
            case "$n" in ''|*[!0-9]*) n=0 ;; esac
            if [ "$n" -ge 1 ]; then
                local nominal diff pct fixed=""
                nominal=$(nominal_threads "$model")
                if [ -n "$nominal" ]; then
                    diff=$(( nominal - n )); [ "$diff" -lt 0 ] && diff=$(( -diff ))
                    if [ $(( diff * 100 )) -gt $(( nominal * 10 )) ]; then
                        pct=$(( diff * 100 / nominal ))
                        echo "型号识别结果与实测线程不符（检测到机型 $model 标称 ${nominal} 线程，实测 ${n} 线程，偏差 ${pct}%）"
                        # 仅海光四位数字型号标称与实测矛盾时按实测线程分界修正；
                        # AMD/Intel 品牌型号（EPYC-xxxx/Xeon-xxxx）无海光型号概念，保留品牌标注、不做分界修正
                        case "$model" in
                            [0-9][0-9][0-9][0-9])
                                if   [ "$n" -ge 120 ]; then fixed=7380
                                elif [ "$n" -ge 90 ];  then fixed=7360
                                elif [ "$n" -ge 64 ];  then fixed=5380
                                fi
                                ;;
                        esac
                        if [ -n "$fixed" ] && [ "$fixed" != "$model" ]; then
                            echo "已按实测线程修正机型：$model → $fixed"
                            model="$fixed"
                        fi
                    fi
                fi
            fi
        else
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
            src="逻辑线程分界/内存兜底（CPU 信息识别失败）"
        fi
        echo "检测到机型 $model（来源: $src）"
        log_op "model-detect 机型 $model（来源: $src）"
    fi
    case "$model" in
        [0-9][0-9][0-9][0-9]|EPYC-[0-9][0-9]*|Xeon-[0-9][0-9]*) ;;
        *) echo "未知机型：$model（应为品牌-型号格式：海光四位数字型号如 5380|7380|7360，AMD EPYC-xxxx，Intel Xeon-xxxx，或 auto）"; exit 1 ;;
    esac

    # CPU 参数：按逻辑线程推导（显式 --cpu 直接使用）；hdd 模式不推导、不校验
    # 逻辑线程 = 物理核 × 每核线程数（SMT 探测，未知默认开）；物理核识别失败时回退 round(nproc × CPU_MAX_PCT%)
    # SMT 状态在此探测一次（参与 CPU worker 分配）；hdd 模式不探测（不推导 CPU）
    local cpus="" phys_cores=0 cpu_note="" smt_txt=""
    if [ "$type" != "hdd" ]; then
        smt_txt=$(smt_status)
        cpus=$(logical_cpus)
        case "$cpus" in ''|*[!0-9]*) cpus="" ;; esac
        [ -n "$cpus" ] && check_model_threads "$model" "$cpus" "$smt_txt"
        if [ -z "$cpu_opt" ]; then
            if ! cpu_workers_auto; then
                echo "无法探测 CPU 数量（nproc 与物理核均不可用），已中止；请检查 nproc/lscpu 或用 --cpu 显式指定"
                exit 1
            fi
            cpu_opt="$CPU_WORKERS_AUTO"
            phys_cores="$CPU_PHYS_CORES"
            if [ "$phys_cores" -ge 1 ]; then
                if [ "$CPU_SMT_TPC" = "1" ]; then
                    cpu_note="（逻辑线程 ${CPU_LOGICAL_THREADS} × 25/32，SMT 关/每核1线程）"
                else
                    cpu_note="（逻辑线程 ${CPU_LOGICAL_THREADS} × 25/32，SMT 开/每核2线程）"
                fi
            else
                cpu_note="（物理核识别失败，nproc ${cpus} × ${CPU_MAX_PCT}%）"
            fi
        else
            cpu_note="（显式 --cpu）"
            phys_cores=$(physical_cores)
        fi
    fi

    # 内存参数（--vm / --vm-bytes）在下方“内存计划”段按实测 DIMM 根数与 MemTotal 推导；
    # 显式参数优先，显式传空值（如 --vm ""）按“未提供”处理，回退自动探测
    [ -z "$hdd_bytes_opt" ] && hdd_bytes_opt="10G"

    # 前置校验：stress 已安装
    command -v stress >/dev/null 2>&1 || { echo "未找到 stress，请先运行 bash install.sh 安装"; exit 1; }

    # hdd/combo 前置校验：先全量收集并校验压测盘目录，存在且任一无效即整体退出（不启动任何 stress、不建结果目录，防孤儿进程）
    # combo 模式目录集合可为空（无数据盘降级为仅 CPU/内存，或配合 --sysdisk 仅压系统盘）；
    # hdd 模式目录集合非空，仅当加 --sysdisk 时允许为空（无数据盘时仅压系统盘）；
    # --sysdisk-only 时数据盘集合强制为空，不扫描 /mnt/HDD*、不校验挂载（无论是否存在数据盘）
    local dirs=() d
    if [ "$sysdisk_only" -eq 1 ]; then
        dirs=()
    elif [ "$type" = "hdd" ] || [ "$type" = "combo" ]; then
        if [ "$dirs_given" -eq 1 ]; then
            dirs=($dirs_opt)          # 显式 --dirs（含空串）：空串表示不压数据盘
        elif [ "$type" = "combo" ] && [ "$peer_given" -eq 1 ]; then
            # --peer-disks 出现即视为显式声明外部盘流：不再自动 glob /mnt/HDD*，避免 combo 内重复压盘
            dirs=()
            echo "提示：已指定 --peer-disks=${peer_disks}，combo 不再自动扫描 /mnt/HDD*（不启动 hdd 进程）"
        else
            dirs=(/mnt/HDD*)
            [ -e "${dirs[0]}" ] || {
                dirs=()
                if [ "$type" = "hdd" ]; then
                    if [ "$sysdisk" -eq 1 ]; then
                        echo "未发现 /mnt/HDD* 挂载点，hdd 模式仅压系统盘"
                    else
                        echo "未发现 /mnt/HDD* 挂载点，请先运行 bash disk-mount.sh mount 或使用 --dirs 指定"; exit 1
                    fi
                else
                    echo "警告：未发现 /mnt/HDD* 挂载点，combo 模式无数据盘（仅 CPU/内存，或配合 --sysdisk 压系统盘）"
                fi
            }
        fi
        if [ "${#dirs[@]}" -gt 0 ]; then
            for d in "${dirs[@]}"; do
                [ -d "$d" ] || { echo "挂载点不存在：$d（请先挂载或检查 --dirs）"; exit 1; }
            done
            # 目录存在≠已挂载（umount 不删目录），多轮流程第二轮会误把压测文件写到系统根文件系统。
            # 默认 glob 与显式 --dirs 一视同仁：每个目录必须是已挂载的独立文件系统，且底层设备不是根设备。
            local root_dev dev
            root_dev=$("$DF_BIN" -P / 2>/dev/null | awk 'NR==2{print $1}')
            for d in "${dirs[@]}"; do
                dev=$("$FINDMNT_BIN" -n -o SOURCE --target "$d" 2>/dev/null | head -1)
                if [ -z "$dev" ] || { [ -n "$root_dev" ] && [ "$dev" = "$root_dev" ]; }; then
                    echo "目录 $d 不是已挂载的独立文件系统（设备=${dev:-未挂载}，系统盘=${root_dev:-未知}），不能作为压测盘"
                    echo "请先运行 bash disk-mount.sh mount 挂载测试盘，或用 --dirs 显式指定压测目录"
                    exit 1
                fi
            done
        elif [ "$type" = "hdd" ] && [ "$sysdisk" -ne 1 ]; then
            echo "未指定任何压测盘目录（--dirs 为空）"; exit 1
        elif [ "$type" = "combo" ] && [ "$dirs_given" -eq 1 ]; then
            echo "警告：combo 模式无数据盘（--dirs 为空，仅 CPU/内存，或配合 --sysdisk 压系统盘）"
        fi
    fi

    # --sysdisk 前置校验：建系统盘压测目录并预检 / 可用空间（hdd-bytes 按 G 换算 ×1.2），不足整体退出（不启动任何进程、不建结果目录）
    if [ "$sysdisk" -eq 1 ] && { [ "$type" = "hdd" ] || [ "$type" = "combo" ]; }; then
        mkdir -p /stresstest-hdd 2>/dev/null || { echo "无法创建系统盘压测目录 /stresstest-hdd（可能需要 root 权限）"; exit 1; }
        local gb need_kb avail_kb
        gb="${hdd_bytes_opt%[Gg]}"
        case "$gb" in
            ''|*[!0-9]*) echo "系统盘压测（--sysdisk/--sysdisk-only）空间预检要求 hdd-bytes 以 G 为单位（当前：$hdd_bytes_opt）"; exit 1 ;;
        esac
        need_kb=$(( gb * 12 * 1048576 / 10 ))
        avail_kb=$("$DF_BIN" -P / 2>/dev/null | awk 'NR==2{print $4}')
        if [ -z "$avail_kb" ] || [ "$avail_kb" -lt "$need_kb" ]; then
            echo "系统盘 / 可用空间不足：需要 ≥ ${need_kb} kB（${hdd_bytes_opt}×1.2），当前可用 ${avail_kb:-未知} kB"
            exit 1
        fi
    fi

    # 盘数 D（数据盘目录数 + --sysdisk 的系统盘）；仅 hdd/combo 计入
    local disk_streams=0 disk_streams_eff=0 disk_streams_source="actual"
    if [ "$type" = "hdd" ] || [ "$type" = "combo" ]; then
        disk_streams=${#dirs[@]}
        [ "$sysdisk" -eq 1 ] && disk_streams=$((disk_streams + 1))
    fi
    # 有效盘流：combo/mem 显式 --peer-disks 时取 max(实际盘数, peer)；hdd/cpu 只用实际盘数。
    # peer 只参与 cap_disk 预留与展示，不产生 hdd 进程。
    disk_streams_eff="$disk_streams"
    if [ "$peer_given" -eq 1 ]; then
        if [ "$peer_disks" -gt "$disk_streams" ]; then
            disk_streams_eff="$peer_disks"
            disk_streams_source="peer"
        elif [ "$peer_disks" -lt "$disk_streams" ]; then
            disk_streams_source="actual"
        else
            disk_streams_source="max"
        fi
    fi

    # 内存计划（仅 mem/combo）：DIMM 根数/容量决定单 worker，三道上限取最小后逐 GiB 下调。
    # 放在结果目录创建之前：探测/推导失败时直接退出，不留下 <时间戳>-mem 结果目录、不启动 stress。
    # 显式 --vm / --vm-bytes 优先且不被改写（显式传空值按“未提供”处理，回退自动探测）。
    local mem_dimm_desc="" mem_per_desc="" mem_target_desc="" mem_plan_desc="" mem_total_gb_desc=""
    local mem_cap_desc="" mem_need_desc="" vm_keep="no" res_plan_line=""
    local per_g="" cap_module_g="" cap_mem_g="" cap_disk_g=""
    if [ "$type" = "mem" ] || [ "$type" = "combo" ]; then
        vm_keep="yes"
        local total_mb="" probe_source="none" probe_count=0 probe_caps="" uniform_g="" module_count=0
        local cap_module_mb="" cap_mem_mb="" cap_disk_mb="" cap_mb="" cap_g=""
        local per_mb=0 need_mb=0 reserve_g=0 clamped=0 old_per_g=0 dimm_cap="" fallback_reason=""

        dimm_count_auto >/dev/null     # 始终探测：显式 --vm 也需 DIMM 根数做一致性判定
        probe_source="$DIMM_SOURCE"; probe_count="$DIMM_COUNT"; probe_caps="$DIMM_CAPS"

        # 1) worker 数 = DIMM 根数（显式 --vm 优先）
        if [ -n "$vm_opt" ]; then
            case "$vm_opt" in
                ''|*[!0-9]*) echo "参数 --vm 取值非法：$vm_opt（应为正整数根数）"; exit 1 ;;
            esac
            vm_opt=$(( 10#$vm_opt ))      # 前导零按十进制归一化（08→8、010→10）
            [ "$vm_opt" -ge 1 ] || { echo "参数 --vm 取值非法：$vm_opt（应为正整数根数）"; exit 1; }
            DIMM_SOURCE="显式 --vm"
        else
            vm_opt="$probe_count"
            if [ "$probe_source" = "none" ] || [ "$vm_opt" -lt 1 ]; then
                local sg_total_mb=""
                sg_total_mb=$(mem_total_mb)
                echo "无法探测内存条根数（dmidecode/EDAC 均不可用），本次 ${type} 压测已中止。"
                if [ -n "$sg_total_mb" ] && mem_plan "$sg_total_mb" 16; then
                    echo "已按 MemTotal $(( (sg_total_mb + 512) / 1024 ))G 算好一条可直接执行的命令（16 个 worker 平分 ${MEM_TARGET_PCT}%，总量 ${PLAN_TOTAL_GB}G，未超 ${MEM_TOTAL_MAX_PCT}% 上限）："
                    echo "  bash stress-test.sh start ${type} --vm 16 --vm-bytes ${PLAN_PER_GB}G --timeout ${timeout}"
                    echo "若已知实际内存条根数，更推荐只填根数、单 worker 字节由脚本自动推导："
                    echo "  bash stress-test.sh start ${type} --vm <实际根数> --timeout ${timeout}"
                else
                    echo "MemTotal 也无法读取，需同时显式给出根数与单 worker 字节（总量应约等于 MemTotal × ${MEM_TARGET_PCT}%），例如："
                    echo "  bash stress-test.sh start ${type} --vm <实际根数> --vm-bytes 26G --timeout ${timeout}"
                fi
                echo "根数获取：开机 BIOS 内存信息或机箱/主板标签；已装 lshw 时可用 sudo lshw -class memory | grep -c 'bank:'"
                echo "装上 dmidecode 后重试即可恢复自动探测（离线包已内置：在包目录执行 sudo bash install.sh）；combo 的 --dirs / --sysdisk 等参数请按原命令补上。"
                exit 1
            fi
        fi

        # 2) MemTotal 与三道 cap（显式 --vm-bytes 时 MemTotal 可缺失，仅告警）
        total_mb=$(mem_total_mb)
        if [ -z "$total_mb" ] && [ -z "$vm_bytes_opt" ]; then
            echo "无法读取 MemTotal（$MEMINFO_FILE），已中止；请检查该文件或用 --vm-bytes 显式指定"
            exit 1
        fi
        if [ -n "$total_mb" ]; then
            mem_total_gb_desc=$(( (total_mb + 512) / 1024 ))
            cap_mem_mb=$(( total_mb * MEM_TOTAL_MAX_PCT / 100 ))
            cap_mem_g=$(( cap_mem_mb / 1024 ))
            if [ "$disk_streams_eff" -gt 0 ]; then
                local hdd_mb disk_need_mb
                hdd_mb=$(parse_size_mb "$hdd_bytes_opt")
                case "$hdd_mb" in ''|*[!0-9]*) hdd_mb=10240 ;; esac
                disk_need_mb=$(( disk_streams_eff * hdd_mb * DISK_CACHE_FACTOR_PCT / 100 + DISK_CACHE_MIN_G * 1024 ))
                cap_disk_mb=$(( total_mb - disk_need_mb ))
                if [ "$cap_disk_mb" -le 0 ]; then
                    echo "内存不足以支撑当前盘流（${disk_streams_eff} 个 hdd 流预留 $(( disk_need_mb / 1024 ))G，MemTotal ${mem_total_gb_desc}G），请减少盘数或降低 --hdd-bytes"
                    exit 1
                fi
                cap_disk_g=$(( cap_disk_mb / 1024 ))
            fi
        fi

        # 3) 容量一致性：仅 dmidecode 且全部 token 一致时可用单根规则；VM 数须等于 DIMM 根数
        if [ "$probe_source" = "dmidecode" ] && [ "$probe_count" -ge 1 ]; then
            uniform_g=$(dimm_cap_gib_uniform "$probe_caps")
        fi
        module_count="$probe_count"
        if [ -n "$uniform_g" ] && [ "$module_count" -ge 1 ] && [ "$vm_opt" -eq "$module_count" ]; then
            cap_module_mb=$(( uniform_g * module_count * 1024 * MEM_MAX_PCT / 100 ))
            cap_module_g=$(( cap_module_mb / 1024 ))
        fi
        cap_mb=""
        [ -n "$cap_module_mb" ] && cap_mb="$cap_module_mb"
        if [ -n "$cap_mem_mb" ] && { [ -z "$cap_mb" ] || [ "$cap_mem_mb" -lt "$cap_mb" ]; }; then cap_mb="$cap_mem_mb"; fi
        if [ -n "$cap_disk_mb" ] && { [ -z "$cap_mb" ] || [ "$cap_disk_mb" -lt "$cap_mb" ]; }; then cap_mb="$cap_disk_mb"; fi
        [ -n "$cap_mb" ] && cap_g=$(( cap_mb / 1024 ))

        # 4) 单 worker 字节
        if [ -n "$vm_bytes_opt" ]; then
            # 显式 --vm-bytes 原样保留，只告警不裁剪
            bytes_from_preset=0
            local chk_mb=""
            chk_mb=$(parse_size_mb "$vm_bytes_opt")
            case "$chk_mb" in ''|*[!0-9]*) chk_mb=0 ;; esac
            if [ "$chk_mb" -lt 1 ]; then
                echo "参数 --vm-bytes 取值非法：$vm_bytes_opt（应为整数加单位，如 --vm-bytes 51G）"
                exit 1
            fi
            per_mb=$chk_mb
            per_g=$(( per_mb / 1024 ))
            mem_target_desc="内存目标: 未推导（显式 --vm-bytes）"
        elif [ -n "$uniform_g" ] && [ "$vm_opt" -eq "$module_count" ] && [ -n "$cap_mb" ]; then
            # 单根规则：单 worker = 单条容量 − max(6G, 单条容量/8)
            bytes_from_preset=1
            reserve_g=$(( uniform_g / 8 )); [ "$reserve_g" -lt 6 ] && reserve_g=6
            per_g=$(( uniform_g - reserve_g )); [ "$per_g" -lt 1 ] && per_g=1
            old_per_g=$per_g
            while [ $(( per_g * vm_opt * 1024 )) -gt "$cap_mb" ] && [ "$per_g" -gt 1 ]; do
                per_g=$(( per_g - 1 )); clamped=1
            done
            if [ $(( per_g * vm_opt * 1024 )) -gt "$cap_mb" ]; then
                echo "单 worker 已降至 1G 仍超上限（MemTotal ${mem_total_gb_desc}G / ${vm_opt} 根，分配上限 ${cap_g}G），无法压测"
                exit 1
            fi
            vm_bytes_opt="${per_g}G"
            mem_target_desc="内存目标: $(( per_g * vm_opt ))G（实际下发 ${vm_opt}×${per_g}G；单根 ${uniform_g}G − 预留 ${reserve_g}G）"
            if [ "$clamped" -eq 1 ]; then
                echo "已按分配上限裁剪：${vm_opt}×${old_per_g}G → ${vm_opt}×${per_g}G（上限 ${cap_g}G）"
                log_op "mem-clamp dimms=${vm_opt} old_per=${old_per_g}G new_per=${per_g}G cap=${cap_g}G"
                mem_target_desc="${mem_target_desc}，超上限已下调"
            fi
        else
            # 兜底：混合容量 / EDAC 无容量 / 显式 --vm ≠ DIMM 数 → MemTotal×82% 均分，上限 92%
            bytes_from_preset=1
            if [ "$probe_count" -lt 1 ]; then
                fallback_reason="未探测到 DIMM 容量"
            elif [ "$probe_source" = "edac" ]; then
                fallback_reason="EDAC 无容量"
            elif [ "$vm_opt" -ne "$module_count" ]; then
                fallback_reason="显式 --vm=${vm_opt} 与 DIMM 根数=${module_count} 不一致"
            else
                fallback_reason="DIMM 容量混合或无法解析"
            fi
            log_op "mem-fallback reason=${fallback_reason} per=${MEM_TARGET_PCT}% cap=${MEM_TOTAL_MAX_PCT}%"
            if ! mem_plan "$total_mb" "$vm_opt"; then
                echo "单 worker 内存不足 1G（MemTotal $(( total_mb / 1024 ))G / ${vm_opt} 根），无法压测"
                exit 1
            fi
            per_g=$PLAN_PER_GB
            # 三道上限取最小后仍逐 GiB 下调（如 combo 多盘时 cap_disk 更低）
            if [ -n "$cap_mb" ]; then
                old_per_g=$per_g
                while [ $(( per_g * vm_opt * 1024 )) -gt "$cap_mb" ] && [ "$per_g" -gt 1 ]; do
                    per_g=$(( per_g - 1 )); clamped=1
                done
                if [ $(( per_g * vm_opt * 1024 )) -gt "$cap_mb" ]; then
                    echo "单 worker 已降至 1G 仍超上限（MemTotal ${mem_total_gb_desc}G / ${vm_opt} 根，分配上限 ${cap_g}G），无法压测"
                    exit 1
                fi
            fi
            vm_bytes_opt="${per_g}G"
            mem_target_desc="内存目标: $(( per_g * vm_opt ))G（实际下发 ${vm_opt}×${per_g}G；MemTotal ${mem_total_gb_desc}G × ${MEM_TARGET_PCT}% ≈ ${PLAN_TARGET_GB}G，兜底均分；原因: ${fallback_reason}）"
            if [ "$clamped" -eq 1 ]; then
                echo "已按分配上限裁剪：${vm_opt}×${old_per_g}G → ${vm_opt}×${per_g}G（上限 ${cap_g}G）"
                log_op "mem-clamp dimms=${vm_opt} old_per=${old_per_g}G new_per=${per_g}G cap=${cap_g}G"
                mem_target_desc="${mem_target_desc}，超上限已下调"
            fi
        fi

        # 5) 落盘用描述：根数来源与单根容量
        mem_dimm_desc="内存条根数: ${vm_opt}（来源: ${DIMM_SOURCE}）"
        if [ -n "$uniform_g" ] && [ "$vm_opt" -eq "$module_count" ]; then
            dimm_cap=$(dimm_capacity_desc "$probe_caps")
            mem_per_desc="单根容量: ${dimm_cap:-${uniform_g} GiB}"
        elif [ "$probe_source" = "dmidecode" ]; then
            dimm_cap=$(dimm_capacity_desc "$probe_caps")
            mem_per_desc="单根容量: ${dimm_cap:-未探测}"
        elif [ "$probe_source" = "edac" ]; then
            if [ "$bytes_from_preset" -eq 1 ]; then
                mem_per_desc="单根容量: 均分 ${per_g}G（MemTotal / 根数）"
            else
                mem_per_desc="单根容量: 均分（MemTotal / 根数，未推导）"
            fi
        else
            mem_per_desc="单根容量: 未探测"
        fi

        # 6) 分配上限描述与需求核对
        if [ -n "$cap_mb" ]; then
            local cm_txt cn_txt cd_txt
            if [ -n "$cap_module_g" ]; then cm_txt="${cap_module_g}G（模块总容量 × ${MEM_MAX_PCT}%）"; else cm_txt="不生效"; fi
            if [ -n "$total_mb" ]; then
                cn_txt="${cap_mem_g}G（MemTotal × ${MEM_TOTAL_MAX_PCT}%）"
                if [ "$disk_streams_eff" -gt 0 ]; then
                    cd_txt="${cap_disk_g}G（预留 ${disk_streams_eff}×${hdd_bytes_opt}×${DISK_CACHE_FACTOR_PCT}%+${DISK_CACHE_MIN_G}G）"
                else
                    cd_txt="不生效（无 hdd 流）"
                fi
                mem_cap_desc="内存分配上限: ${cap_g}G（取最小：${cm_txt} / ${cn_txt} / 磁盘后 ${cd_txt}）"
            else
                echo "提示：MemTotal 不可用，cap_mem/cap_disk 已跳过，仅按模块容量上限判定"
                mem_cap_desc="内存分配上限: ${cap_g}G（MemTotal 不可用，cap_mem/cap_disk 已跳过；${cm_txt}）"
            fi
            if [ "$bytes_from_preset" -eq 1 ]; then per_mb=$(( per_g * 1024 )); fi
            need_mb=$(( vm_opt * per_mb ))
            local need_txt
            if [ $(( need_mb % 1024 )) -eq 0 ]; then need_txt="$(( need_mb / 1024 ))G"; else need_txt="${need_mb}M"; fi
            if [ "$need_mb" -le "$cap_mb" ]; then
                echo "内存需求 ${need_txt} 未超过分配上限 ${cap_g}G"
                mem_need_desc="内存需求: 实际 ${need_txt}（未超限）"
            elif [ "$bytes_from_preset" -eq 0 ]; then
                echo "警告：内存需求 ${need_txt} 超过物理内存分配上限 ${cap_g}G，可能触发 OOM；按显式参数继续"
                mem_need_desc="内存需求: 实际 ${need_txt}（显式 --vm-bytes，超分配上限）"
            else
                echo "警告：内存需求 ${need_txt} 超过分配上限 ${cap_g}G，按当前参数继续"
                mem_need_desc="内存需求: 实际 ${need_txt}（超分配上限）"
            fi
        elif [ -z "$total_mb" ]; then
            echo "提示：MemTotal 不可用，cap_mem/cap_disk 无法计算，未做内存裁剪"
            mem_cap_desc="内存分配上限: 未知（MemTotal 不可用，cap_mem/cap_disk 已跳过）"
            mem_need_desc="内存需求: 未做内存裁剪（MemTotal 不可用）"
        else
            echo "提示：无法解析 vm-bytes（$vm_bytes_opt），未做内存裁剪"
            mem_cap_desc="内存分配上限: 未知（无法解析 vm-bytes）"
            mem_need_desc="内存需求: 未做内存裁剪（无法解析 vm-bytes）"
        fi

        # 7) 推导依据落盘（显式 --vm-bytes 保留原始值与规范化 MB，不用取整 GiB 冒充）
        local plan_per="" plan_total=""
        if [ "$bytes_from_preset" -eq 1 ]; then
            plan_per="${per_g}G"
            plan_total="$(( per_g * vm_opt ))G"
        else
            plan_per="$vm_bytes_opt"
            if [ $(( per_mb % 1024 )) -eq 0 ]; then
                plan_total="$(( per_mb * vm_opt / 1024 ))G"
            else
                plan_total="$(( per_mb * vm_opt ))M"
            fi
        fi
        log_op "mem-plan dimms=${vm_opt} source=${DIMM_SOURCE} per=${plan_per} total=${plan_total} per_mb=${per_mb}M total_mb=$(( per_mb * vm_opt ))M target=${MEM_TARGET_PCT}% cap=${cap_g:-unknown}G cap_module_g=${cap_module_g:-none} cap_mem_g=${cap_mem_g:-none} cap_disk_g=${cap_disk_g:-none} disk_streams=${disk_streams} peer_disks=${peer_disks} disk_streams_eff=${disk_streams_eff} disk_streams_source=${disk_streams_source} vm_keep=${vm_keep} cpu=${cpu_opt}(nproc=${cpus:-none},physical_cores=${phys_cores}) smt=${smt_txt:-none}"
        mem_plan_desc="内存计划：${vm_opt} 根 × ${plan_per} = ${plan_total}（来源: ${DIMM_SOURCE}；上限 ${cap_g:-未知}G；--vm-keep 常驻）"
    fi

    # 资源计划汇总（显示与落盘）：覆盖 physical_cores/nproc/cpu_workers/dimms/per_worker_g/
    # mem_total_g/cap_module_g/cap_mem_g/cap_disk_g/disk_streams/peer_disks/disk_streams_eff/vm_keep/smt
    local per_worker_g_txt="none" per_worker_mb_txt="none" per_worker_raw="none"
    if [ "$type" = "mem" ] || [ "$type" = "combo" ]; then
        per_worker_mb_txt="$per_mb"
        per_worker_raw="$vm_bytes_opt"
        if [ $(( per_mb % 1024 )) -eq 0 ]; then per_worker_g_txt=$(( per_mb / 1024 )); fi
    fi
    res_plan_line="physical_cores=${phys_cores:-none} nproc=${cpus:-none} cpu_workers=${cpu_opt:-none} dimms=${vm_opt:-none} per_worker_g=${per_worker_g_txt} per_worker_mb=${per_worker_mb_txt} per_worker_raw=${per_worker_raw} mem_total_g=${mem_total_gb_desc:-none} cap_module_g=${cap_module_g:-none} cap_mem_g=${cap_mem_g:-none} cap_disk_g=${cap_disk_g:-none} disk_streams=${disk_streams} peer_disks=${peer_disks} disk_streams_eff=${disk_streams_eff} disk_streams_source=${disk_streams_source} vm_keep=${vm_keep} smt=${smt_txt:-none}"
    log_op "resource-plan $res_plan_line"

    # 建结果目录（时间戳，防覆盖；同秒冲突时顺延）
    local ts dir
    while :; do
        ts=$(date '+%Y%m%d-%H%M%S')
        dir="$STRESS_TEST_ROOT/$ts-$type"
        [ -d "$dir" ] || break
        sleep 1
    done
    mkdir -p "$dir" || { echo "无法创建结果目录：$dir"; exit 1; }

    # 组装 stress 参数与超时秒数（mem/combo 固定追加 --vm-keep，cpu/hdd 不加）
    local stress_args timeout_sec start_time
    case "$type" in
        cpu) stress_args="--cpu $cpu_opt --timeout $timeout" ;;
        mem) stress_args="--vm $vm_opt --vm-bytes $vm_bytes_opt --vm-keep --timeout $timeout" ;;
        hdd) stress_args="--hdd 1 --hdd-bytes $hdd_bytes_opt --timeout $timeout" ;;
        combo) stress_args="--cpu $cpu_opt --vm $vm_opt --vm-bytes $vm_bytes_opt --vm-keep --timeout $timeout" ;;
    esac
    timeout_sec=$(parse_timeout_sec "$timeout")
    start_time=$(now)

    # 写 run-config.txt 与 info-before.txt
    {
        echo "机型: $model"
        echo "类型: $type"
        echo "开始时间: $start_time"
        echo "超时: $timeout"
        echo "超时秒数: $timeout_sec"
        echo "监控间隔: ${MONITOR_INTERVAL}s"
        echo "盘流: peer_disks=$peer_disks disk_streams=$disk_streams disk_streams_eff=$disk_streams_eff disk_streams_source=$disk_streams_source"
        echo "结果目录: $dir"
        case "$type" in
            cpu)
                echo "物理核数: $phys_cores"
                echo "CPU 逻辑线程: ${cpus:-未知}"
                echo "SMT 状态: ${smt_txt}"
                echo "CPU worker 数: $cpu_opt$cpu_note"
                echo "VM keep: $vm_keep"
                echo "HDD 进程数: $disk_streams"
                echo "资源计划: $res_plan_line"
                ;;
            mem)
                echo "物理核数: $phys_cores"
                echo "CPU 逻辑线程: ${cpus:-未知}"
                echo "SMT 状态: ${smt_txt}"
                echo "CPU worker 数: $cpu_opt$cpu_note"
                echo "$mem_dimm_desc"
                echo "$mem_per_desc"
                echo "$mem_target_desc"
                echo "$mem_cap_desc"
                echo "VM worker 数: $vm_opt"
                echo "VM 字节: $vm_bytes_opt"
                echo "VM keep: $vm_keep（mem 固定追加 --vm-keep）"
                echo "HDD 进程数: $disk_streams"
                echo "$mem_need_desc"
                echo "资源计划: $res_plan_line"
                ;;
            hdd)
                echo "HDD 字节: $hdd_bytes_opt"
                echo "HDD 进程数: $disk_streams"
                echo "VM keep: $vm_keep"
                echo "资源计划: $res_plan_line"
                ;;
            combo)
                echo "物理核数: $phys_cores"
                echo "CPU 逻辑线程: ${cpus:-未知}"
                echo "SMT 状态: ${smt_txt}"
                echo "CPU worker 数: $cpu_opt$cpu_note"
                echo "$mem_dimm_desc"
                echo "$mem_per_desc"
                echo "$mem_target_desc"
                echo "$mem_cap_desc"
                echo "VM worker 数: $vm_opt"
                echo "VM 字节: $vm_bytes_opt"
                echo "VM keep: $vm_keep（combo 固定追加 --vm-keep）"
                echo "HDD 字节: $hdd_bytes_opt"
                echo "HDD 进程数: $disk_streams"
                echo "$mem_need_desc"
                echo "资源计划: $res_plan_line"
                ;;
        esac
        # 系统盘口径（FR-10）：仅 hdd/combo 的 --sysdisk 生效
        if [ "$sysdisk" -eq 1 ] && { [ "$type" = "hdd" ] || [ "$type" = "combo" ]; }; then
            echo "压测对象: 系统盘（根文件系统压测）"
            echo "覆盖边界: 不覆盖 /boot、/boot/efi、swap、未分配空间；LVM/RAID 下写入可能跨多个物理盘"
        fi
        echo "错误日志: error.log（stderr 实时记录）"
        echo "命令: stress $stress_args"
    } > "$dir/run-config.txt"

    # 写设备归因文件（FR-6）：数据盘目录 + 系统盘（--sysdisk 时按根文件系统）的设备名，
    # 供 monitor-loop 做 dmesg I/O 错误按盘归因；文件为空表示不过滤
    if [ "$type" = "hdd" ] || [ "$type" = "combo" ]; then
        local dev_sources=("${dirs[@]}")
        [ "$sysdisk" -eq 1 ] && dev_sources+=("/")
        write_devices_file "$dir/devices.txt" "${dev_sources[@]}"
    fi

    {
        echo "==== lscpu ===="
        lscpu 2>&1
        echo "==== free -h ===="
        free -h 2>&1
        echo "==== df -h ===="
        df -h 2>&1
        echo "==== lsblk ===="
        lsblk 2>&1
        echo "==== dmidecode -t 17 ===="
        if ! "$DMI_BIN" -t 17 2>&1; then
            echo "dmidecode 不可用（$DMI_BIN），无法采集内存条信息"
        fi
        echo "==== numactl -H ===="
        if command -v numactl >/dev/null 2>&1; then
            numactl -H 2>&1
        else
            echo "numactl 未安装"
        fi
        echo "==== stress --version ===="
        stress --version 2>&1
    } > "$dir/info-before.txt"

    # 初始化错误日志（表头注释；stderr 实时写入，monitor 巡检追加运行期异常，空=无错误）
    echo "# 压测错误日志（空=无错误） 开始时间: $(now)" > "$dir/error.log"

    # 后台启动 stress（nohup；combo 先起 CPU/内存组合进程，再每盘一条 hdd，--sysdisk 再补系统盘；
    # 目录已在上方全量校验，这里只负责启动）
    : > "$dir/stress.pids"
    if [ "$type" = "combo" ] || [ "$type" = "hdd" ]; then
        if [ "$type" = "combo" ]; then
            nohup sh -c 'stress $1 1>"$2/stress.log" 2>>"$2/error.log"; echo $? > "$2/stress.exitcode"' _ "$stress_args" "$dir" >/dev/null 2>&1 &
            echo "$!" >> "$dir/stress.pids"
        fi
        local i=1 num
        for d in "${dirs[@]}"; do
            num=$(printf "%02d" "$i")
            nohup sh -c 'cd "$1" && stress --hdd 1 --hdd-bytes "$2" --timeout "$3" 1>"$4/stress-HDD$5.log" 2>"$4/error-HDD$5.log"; echo $? > "$4/stress-HDD$5.exitcode"' _ "$d" "$hdd_bytes_opt" "$timeout" "$dir" "$num" >/dev/null 2>&1 &
            echo "$!" >> "$dir/stress.pids"
            i=$((i + 1))
        done
        if [ "$sysdisk" -eq 1 ]; then
            nohup sh -c 'cd "$1" && stress --hdd 1 --hdd-bytes "$2" --timeout "$3" 1>"$4/stress-SYSDISK.log" 2>"$4/error-SYSDISK.log"; echo $? > "$4/stress-SYSDISK.exitcode"' _ "/stresstest-hdd" "$hdd_bytes_opt" "$timeout" "$dir" >/dev/null 2>&1 &
            echo "$!" >> "$dir/stress.pids"
        fi
    else
        nohup sh -c 'stress $1 1>"$2/stress.log" 2>>"$2/error.log"; echo $? > "$2/stress.exitcode"' _ "$stress_args" "$dir" >/dev/null 2>&1 &
        echo "$!" >> "$dir/stress.pids"
    fi

    # 后台启动监控循环（随 stress 全部结束自动退出）
    nohup bash "$SCRIPT" monitor-loop "$dir" >/dev/null 2>&1 &
    echo "$!" > "$dir/monitor.pid"

    # 启动即时快照：记录实际 PID 树、cmdline、cwd、RSS 与实际参数
    runtime_snapshot "$dir" start

    log_op "start type=$type model=$model timeout=$timeout dir=$dir cmd=stress $stress_args"

    # 启动完成提示前打印最终命令与推导依据（设计 6.7），便于操作者当场核对
    echo "资源计划: $res_plan_line"
    [ -n "$mem_plan_desc" ] && echo "$mem_plan_desc"
    [ -n "$mem_cap_desc" ] && echo "$mem_cap_desc"
    echo "命令: stress $stress_args"
    if [ "$type" = "mem" ] || [ "$type" = "combo" ]; then
        local disp_per_mb disp_total mem_derive
        disp_per_mb=$(parse_size_mb "$vm_bytes_opt")
        case "$disp_per_mb" in ''|*[!0-9]*) disp_per_mb=0 ;; esac
        if [ $(( disp_per_mb % 1024 )) -eq 0 ]; then
            disp_total="$(( vm_opt * disp_per_mb / 1024 ))G"
        else
            disp_total="$(( vm_opt * disp_per_mb ))M"
        fi
        if [ "$bytes_from_preset" -eq 1 ]; then
            mem_derive="${vm_opt} 根 × ${vm_bytes_opt} = ${disp_total}（上限 ${cap_g:-未知}G；--vm-keep 常驻）"
        else
            mem_derive="${vm_opt} 根 × ${vm_bytes_opt} = ${disp_total}（显式 --vm-bytes 未推导；--vm-keep 常驻）"
        fi
        echo "推导: CPU ${cpu_opt}${cpu_note}; 内存 ${mem_derive}"
    elif [ "$type" = "cpu" ]; then
        echo "推导: CPU ${cpu_opt}${cpu_note}"
    fi
    echo "已启动 ${type} 压测：$dir"
    echo "查看状态：bash stress-test.sh status"
    echo "实时监控：tail -f $dir/monitor.csv"
}

# ---------- status ----------

cmd_status() {
    local running=0 d
    for d in "$STRESS_TEST_ROOT"/*-cpu "$STRESS_TEST_ROOT"/*-mem "$STRESS_TEST_ROOT"/*-hdd "$STRESS_TEST_ROOT"/*-combo; do
        [ -d "$d" ] || continue
        [ -f "$d/stress.pids" ] || continue
        if [ "$(alive_pids "$d/stress.pids")" -gt 0 ]; then
            running=1
            print_status_dir "$d"
        fi
    done
    if [ "$running" -eq 0 ]; then
        echo "无运行中的压测"
        exit 0
    fi
}

print_status_dir() {
    local d="$1" type="${1##*-}" pids
    echo "---- 运行中压测：$type ----"
    echo "结果目录: $d"
    pids=$(tr '\n' ' ' < "$d/stress.pids")
    echo "stress 存活进程数: $(alive_pids "$d/stress.pids")（PID: $pids）"
    if [ -f "$d/monitor.pid" ] && kill -0 "$(cat "$d/monitor.pid")" 2>/dev/null; then
        echo "监控进程: 运行中（PID $(cat "$d/monitor.pid")）"
    else
        echo "监控进程: 已退出"
    fi
    # 剩余时长估算：run-config 开始时间 + 超时秒数 - 当前时间
    if [ -f "$d/run-config.txt" ]; then
        local start_line timeout_line timeout_sec start_epoch remain
        start_line=$(grep '^开始时间:' "$d/run-config.txt")
        timeout_line=$(grep '^超时秒数:' "$d/run-config.txt")
        timeout_sec="${timeout_line#*: }"
        start_epoch=$(date -d "${start_line#*: }" +%s 2>/dev/null)
        if [ -n "$start_epoch" ] && [ -n "$timeout_sec" ] && [ "$timeout_sec" -gt 0 ] 2>/dev/null; then
            remain=$(( start_epoch + timeout_sec - $(date +%s) ))
            echo "剩余时长估算: $(fmt_remain "$remain")（超时 ${timeout_sec} 秒）"
        fi
    fi
    # 错误日志状态（旧目录无 error.log 时兼容显示；error.log 恒含表头 1 行，行数 ≤1 视为无报错）
    if [ -f "$d/error.log" ]; then
        if [ "$(wc -l < "$d/error.log")" -gt 1 ]; then
            echo "错误日志: error.log（$(wc -l < "$d/error.log") 行，最近条目如下）"
            tail -5 "$d/error.log" | sed 's/^/  /'
        else
            echo "错误日志: 无（未发现报错）"
        fi
    else
        echo "错误日志: 未生成（旧版本目录）"
    fi
    echo "最近监控（tail -5 monitor.csv）:"
    tail -5 "$d/monitor.csv" 2>/dev/null | sed 's/^/  /'
    echo
}

# ---------- stop ----------

cmd_stop() {
    local found=0 d
    for d in "$STRESS_TEST_ROOT"/*-cpu "$STRESS_TEST_ROOT"/*-mem "$STRESS_TEST_ROOT"/*-hdd "$STRESS_TEST_ROOT"/*-combo; do
        [ -d "$d" ] || continue
        [ -f "$d/stress.pids" ] || continue
        local alive mpid mon_alive=0
        alive=$(alive_pids "$d/stress.pids")
        if [ -f "$d/monitor.pid" ]; then
            mpid=$(cat "$d/monitor.pid")
            kill -0 "$mpid" 2>/dev/null && mon_alive=1
        fi
        if [ "$alive" -gt 0 ] || [ "$mon_alive" -eq 1 ]; then
            found=1
            stop_one "$d"
        fi
    done
    if [ "$found" -eq 0 ]; then
        echo "没有运行中的压测，无需停止"
    fi
}

stop_one() {
    local d="$1" pid i=0
    echo "---- 停止：$d ----"
    # 先让监控循环落盘结束状态（TERM 置位停止标记、打断 sleep 等待），最多轮询 2 秒
    if [ -f "$d/monitor.pid" ]; then
        local mpid
        mpid=$(cat "$d/monitor.pid")
        if kill -0 "$mpid" 2>/dev/null; then
            kill -TERM "$mpid" 2>/dev/null
            i=0
            while [ "$i" -lt 10 ] && [ ! -f "$d/status.txt" ] && kill -0 "$mpid" 2>/dev/null; do
                sleep 0.2
                i=$((i + 1))
            done
            if kill -0 "$mpid" 2>/dev/null; then
                kill -KILL "$mpid" 2>/dev/null
            fi
            echo "已停止监控进程 $mpid"
        fi
    fi
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        if kill -0 "$pid" 2>/dev/null; then
            pkill -TERM -P "$pid" 2>/dev/null   # 先杀 stress 子进程
            kill -TERM "$pid" 2>/dev/null
            i=0
            while [ "$i" -lt 6 ] && kill -0 "$pid" 2>/dev/null; do
                sleep 0.5
                i=$((i + 1))
            done
            kill -KILL "$pid" 2>/dev/null
            echo "已停止 stress 进程 $pid"
        fi
    done < "$d/stress.pids"
    log_op "stop dir=$d"
}

# ---------- review ----------

cmd_review() {
    local dir=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --dir) if [ $# -lt 2 ]; then echo "--dir 缺少参数"; exit 1; fi; dir="$2"; shift 2 ;;
            *) echo "未知参数：$1"; usage; exit 1 ;;
        esac
    done
    if [ -z "$dir" ]; then
        dir=$(ls -1d "$STRESS_TEST_ROOT"/*-cpu "$STRESS_TEST_ROOT"/*-mem "$STRESS_TEST_ROOT"/*-hdd "$STRESS_TEST_ROOT"/*-combo 2>/dev/null | sort | tail -1)
        [ -n "$dir" ] || { echo "未找到任何压测结果目录（$STRESS_TEST_ROOT 下无 <时间戳>-<cpu|mem|hdd|combo> 目录）"; exit 1; }
        echo "使用最新结果目录：$dir"
    fi
    [ -d "$dir" ] || { echo "结果目录不存在：$dir"; exit 1; }
    [ -f "$dir/monitor.csv" ] || { echo "未找到监控数据：$dir/monitor.csv"; exit 1; }

    # 统计 monitor.csv：行数 / CPU 均值峰值 / 内存峰值 / IO 峰值
    local rows cpu_mean cpu_max mem_max rd_max wr_max
    read -r rows cpu_mean cpu_max mem_max rd_max wr_max <<< "$(awk -F',' 'NR==1{next} {rows++; cpu+=$3; if($3+0>c)c=$3+0; if($5+0>m)m=$5+0; if($8+0>r)r=$8+0; if($9+0>w)w=$9+0} END{printf "%d %.1f %.1f %.0f %.1f %.1f", rows, (rows?cpu/rows:0), c, m, r, w}' "$dir/monitor.csv")"

    # 监控覆盖时长估算
    local interval_raw interval duration
    interval_raw=$(grep '^监控间隔:' "$dir/run-config.txt" 2>/dev/null | cut -d' ' -f2-)
    interval="${interval_raw%s}"
    # 间隔为空/非数字/0 时回落默认 30 秒，避免后续 duration 乘法与覆盖率除法（除零）中断 review
    case "$interval" in ''|*[!0-9]*|0) interval=30 ;; esac
    if [ "$rows" -ge 2 ]; then duration=$(( (rows - 1) * interval ))
    elif [ "$rows" -eq 1 ]; then duration=$interval
    else duration=0; fi

    # run-config 起止信息
    local type model start_time plan_timeout end_est start_epoch
    type="${dir##*-}"
    model=$(grep '^机型:' "$dir/run-config.txt" 2>/dev/null | cut -d' ' -f2-)
    start_time=$(grep '^开始时间:' "$dir/run-config.txt" 2>/dev/null | cut -d' ' -f2-)
    plan_timeout=$(grep '^超时:' "$dir/run-config.txt" 2>/dev/null | cut -d' ' -f2-)
    # 结束时间按 epoch 推算，避免 date 对 "<时间> + N seconds" 字符串的歧义解析
    start_epoch=$(date -d "$start_time" +%s 2>/dev/null)
    if [ -n "$start_epoch" ]; then
        end_est=$(date -d "@$(( start_epoch + duration ))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
    fi

    # 采样空洞：以 run-config 开始时间为锚点，末行时间距开始即实际跨度；只按行数估算会在机器长时间
    # 无采样（事故中仅 1 行）时严重高估覆盖率。无法解析开始时间或末行时间时判不可判定，不做除法
    local last_ts last_epoch span_sec expected coverage hole
    case "$start_epoch" in ''|*[!0-9]*) start_epoch="" ;; esac
    last_ts=$(awk -F',' 'NF{v=$1} END{if(v!="") print v}' "$dir/monitor.csv" 2>/dev/null)
    last_epoch=$(date -d "$last_ts" +%s 2>/dev/null)
    case "$last_epoch" in ''|*[!0-9]*) last_epoch="" ;; esac
    if [ -n "$start_epoch" ] && [ -n "$last_epoch" ]; then
        span_sec=$(( last_epoch - start_epoch ))
        [ "$span_sec" -lt 0 ] && span_sec=0
        expected=$(( span_sec / interval ))
        [ "$expected" -lt 1 ] && expected=1
        coverage=$(( rows * 100 / expected ))
        [ "$coverage" -gt 100 ] && coverage=100   # 展示值封顶 100%，不影响下方 <90 判定
        if [ "$coverage" -lt 90 ]; then
            hole="是（末行距开始 ${span_sec} 秒，应有 ${expected} 点，实际 ${rows} 点，覆盖率 ${coverage}%）"
        else
            hole="无（覆盖率 ${coverage}%）"
        fi
    else
        coverage="不可判定"
        hole="不可判定（开始时间或末行时间无法解析）"
    fi

    # 结论判定（FR-7，严格顺序）：
    # a) error.log 含 dmesg io: → 异常（内核 I/O 错误，盘故障优先，不被 ENOSPC 掩盖）
    # b) ENOSPC（error.log / error-HDD*.log / error-SYSDISK.log）→ 异常（空间不足，非磁盘故障）
    # c) error.log 命中（检测到 stress / dmesg）→ 异常（压测进程/内核报错）
    # d) 按 status.txt：OK→正常、FAILED→异常（退出码非 0）、ABORTED→按 reason、STOPPED→已手动停止
    # e) 无 status.txt → 沿用旧判定（exitcode 缺失/非 0/error.log 命中 → 异常，否则正常）
    local conclusion="正常" ec code err_lines pids_count ec_count abnormal=0 state="" reason="" is_bad=0 oom_field="" err_hit=0 io_hit=0 enospc=0 un_n=0
    pids_count=$(awk 'NF{n++} END{print n+0}' "$dir/stress.pids" 2>/dev/null)
    ec_count=$(ls "$dir"/*.exitcode 2>/dev/null | wc -l)
    if [ "$pids_count" -gt "$ec_count" ]; then
        abnormal=1
    else
        for ec in "$dir"/*.exitcode; do
            [ -f "$ec" ] || continue
            code=$(cat "$ec" 2>/dev/null)
            [ "$code" = "0" ] || { abnormal=1; break; }
        done
    fi
    if [ -f "$dir/error.log" ]; then
        grep -qE '检测到 stress|dmesg' "$dir/error.log" 2>/dev/null && err_hit=1
        grep -qF 'dmesg io:' "$dir/error.log" 2>/dev/null && io_hit=1
    fi
    [ "$abnormal" -eq 0 ] && [ "$err_hit" -eq 1 ] && abnormal=1
    for f in "$dir/error.log" "$dir"/error-HDD*.log "$dir/error-SYSDISK.log"; do
        [ -f "$f" ] || continue
        if grep -q 'No space left on device' "$f" 2>/dev/null; then enospc=1; break; fi
    done
    if [ -f "$dir/error-unattributed.log" ]; then
        un_n=$(awk 'NF{n++} END{print n+0}' "$dir/error-unattributed.log" 2>/dev/null)
        [ -n "$un_n" ] || un_n=0
    fi
    if [ -f "$dir/status.txt" ]; then
        state=$(grep '^state=' "$dir/status.txt" 2>/dev/null | head -1 | cut -d'=' -f2-)
        reason=$(grep '^reason=' "$dir/status.txt" 2>/dev/null | head -1 | cut -d'=' -f2-)
        oom_field=$(grep '^oom=' "$dir/status.txt" 2>/dev/null | head -1 | cut -d'=' -f2-)
    fi
    if [ "$io_hit" -eq 1 ]; then
        conclusion="异常（内核 I/O 错误，见 error.log）"
    elif [ "$enospc" -eq 1 ]; then
        conclusion="异常（空间不足 ENOSPC，非磁盘故障）"
    elif [ "$err_hit" -eq 1 ]; then
        conclusion="异常（压测进程/内核报错，见 error.log）"
    elif [ -f "$dir/status.txt" ]; then
        case "$state" in
            OK)      conclusion="正常" ;;
            FAILED)  conclusion="异常（退出码非 0）" ;;
            ABORTED)
                case "$reason" in
                    oom-killed)       conclusion="异常（内存耗尽被内核杀死）" ;;
                    missing-exitcode) conclusion="异常（进程异常退出未留退出码）" ;;
                    *)                conclusion="异常（进程异常退出）" ;;
                esac ;;
            STOPPED) conclusion="已手动停止" ;;
            *)       [ "$abnormal" -eq 1 ] && conclusion="异常" ;;
        esac
    else
        [ "$abnormal" -eq 1 ] && conclusion="异常"
    fi
    case "$conclusion" in 异常*) is_bad=1 ;; esac

    # ---------- 执行一致性（计划 vs 实际运行证据） ----------
    # 仅 label=60s/600s/periodic 且 found>0 的快照可作执行一致性证据；start/manual
    # （如任务结束后手动 snapshot）只作展示，不足以判 FAIL。
    # 计划/实际字段缺失一律 UNKNOWN；FAIL 仅在原结论为“正常”时改写结论。
    local ap="$dir/actual-params.txt"
    local cons_status="PASS" cons_lines="" cons_fail=0 cons_unknown=0 cons_conflict=0
    local rc_plan rc_cmd tok plan_cpu="" plan_vm="" plan_per_mb="" plan_disk="" plan_peer="" plan_eff="" plan_keep=""
    local ap_main_cpu="" ap_main_vm="" ap_hdd_n="" ap_hdd_dirs="" ap_vm_keep=""
    local ap_label="" ap_found="" ev_ok=0
    local type_is_mem=0 type_is_hdd=0 block="" planned_kb=0
    local hdd_cwd_list="" hdd_cwd_n=0 block_hdd_n=0 cwd_unknown=0 nl=$'\n'
    case "$type" in mem|combo) type_is_mem=1 ;; esac
    case "$type" in hdd|combo) type_is_hdd=1 ;; esac

    rc_plan=$(grep '^资源计划:' "$dir/run-config.txt" 2>/dev/null | head -1 | cut -d' ' -f2-)
    rc_cmd=$(grep '^命令:' "$dir/run-config.txt" 2>/dev/null | head -1 | cut -d' ' -f2-)
    for tok in $rc_plan; do
        case "$tok" in
            cpu_workers=*)      plan_cpu="${tok#*=}" ;;
            dimms=*)            plan_vm="${tok#*=}" ;;
            per_worker_mb=*)    plan_per_mb="${tok#*=}" ;;
            disk_streams=*)     plan_disk="${tok#*=}" ;;
            peer_disks=*)       plan_peer="${tok#*=}" ;;
            disk_streams_eff=*) plan_eff="${tok#*=}" ;;
            vm_keep=*)          plan_keep="${tok#*=}" ;;
        esac
    done

    if [ ! -f "$ap" ]; then
        cons_status="UNKNOWN"
        cons_unknown=1
        cons_lines="未找到 actual-params.txt（旧版本目录或无运行快照）→ UNKNOWN（不改变结论）\n"
    else
        ap_label=$(read_actual_param "$ap" label)
        ap_found=$(read_actual_param "$ap" found)
        case "$ap_found" in ''|*[!0-9]*) ap_found=0 ;; esac
        if [ "$ap_found" -le 0 ]; then
            cons_status="UNKNOWN"
            cons_unknown=1
            cons_lines="actual-params 无有效进程证据（found=${ap_found:-缺失}）→ UNKNOWN（不改变结论）\n"
        elif ! is_evidence_label "$ap_label"; then
            cons_status="UNKNOWN"
            cons_unknown=1
            cons_lines="仅有启动/手动快照（label=${ap_label:-缺失}），不作为执行一致性证据 → UNKNOWN（不改变结论）\n"
        else
            ev_ok=1
        fi
    fi

    if [ "$ev_ok" -eq 1 ]; then
        ap_main_cpu=$(read_actual_param "$ap" main_cpu)
        ap_main_vm=$(read_actual_param "$ap" main_vm)
        ap_vm_keep=$(read_actual_param "$ap" vm_keep)
        ap_hdd_n=$(read_actual_param "$ap" hdd_processes)
        ap_hdd_dirs=$(read_actual_param "$ap" hdd_dirs)
        case "$ap_hdd_n" in ''|*[!0-9]*) ap_hdd_n="" ;; esac
        block=$(snapshot_block_by_label "$dir/runtime-snapshot.txt" "$ap_label")

        # cwd 集合直接从快照的 cwd= 行解析（保留空格/逗号）；hdd_dirs 为逗号拼接，仅作展示。
        hdd_cwd_list=""; hdd_cwd_n=0; block_hdd_n=0; cwd_unknown=0
        if [ -n "$block" ]; then
            local ln cmd cur_cwd
            while IFS= read -r ln; do
                [ -n "$ln" ] || continue
                cmd=$(snapshot_cmdline "$ln")
                [ -n "$cmd" ] || continue
                is_stress_proc "$cmd" || continue
                case " $cmd " in *" --hdd "*) ;; *) continue ;; esac
                block_hdd_n=$((block_hdd_n + 1))
                cur_cwd=$(snapshot_cwd "$ln")
                case "$cur_cwd" in
                    ''|'?') cwd_unknown=1; continue ;;
                esac
                case "$nl$hdd_cwd_list$nl" in
                    *"$nl$cur_cwd$nl"*) ;;
                    *) hdd_cwd_list="${hdd_cwd_list:+$hdd_cwd_list$nl}$cur_cwd"; hdd_cwd_n=$((hdd_cwd_n + 1)) ;;
                esac
            done <<< "$block"
        fi

        # 1) CPU worker
        if [ "$type" = "hdd" ]; then
            cons_lines="${cons_lines}CPU worker: 计划 无（hdd 模式不压 CPU）/ 实际 ${ap_main_cpu:-未记录} → 不适用\n"
        elif [ -z "$plan_cpu" ] || [ "$plan_cpu" = "none" ]; then
            cons_lines="${cons_lines}CPU worker: 计划 未记录 / 实际 ${ap_main_cpu:-未记录} → UNKNOWN\n"
            cons_unknown=1
        elif [ -z "$ap_main_cpu" ]; then
            cons_lines="${cons_lines}CPU worker: 计划 ${plan_cpu} / 实际 未记录 → UNKNOWN\n"
            cons_unknown=1
        elif [ "$ap_main_cpu" = "$plan_cpu" ]; then
            cons_lines="${cons_lines}CPU worker: 计划 ${plan_cpu} / 实际 ${ap_main_cpu} → PASS\n"
        else
            cons_lines="${cons_lines}CPU worker: 计划 ${plan_cpu} / 实际 ${ap_main_cpu:-未记录} → FAIL\n"
            cons_fail=1
        fi

        # 2) VM worker
        if [ "$type_is_mem" -eq 0 ]; then
            cons_lines="${cons_lines}VM worker: 计划 无（${type} 模式无内存压测）/ 实际 ${ap_main_vm:-未记录} → 不适用\n"
        elif [ -z "$plan_vm" ] || [ "$plan_vm" = "none" ]; then
            cons_lines="${cons_lines}VM worker: 计划 未记录 / 实际 ${ap_main_vm:-未记录} → UNKNOWN\n"
            cons_unknown=1
        elif [ -z "$ap_main_vm" ]; then
            cons_lines="${cons_lines}VM worker: 计划 ${plan_vm} / 实际 未记录 → UNKNOWN\n"
            cons_unknown=1
        elif [ "$ap_main_vm" = "$plan_vm" ]; then
            cons_lines="${cons_lines}VM worker: 计划 ${plan_vm} / 实际 ${ap_main_vm} → PASS\n"
        else
            cons_lines="${cons_lines}VM worker: 计划 ${plan_vm} / 实际 ${ap_main_vm:-未记录} → FAIL\n"
            cons_fail=1
        fi

        # 3) mem/combo 必须 --vm-keep（常驻内存）
        if [ "$type_is_mem" -eq 1 ]; then
            if [ -z "$plan_keep" ] || [ "$plan_keep" = "none" ]; then
                cons_lines="${cons_lines}vm_keep: 计划 未记录 / 实际 ${ap_vm_keep:-未记录} → UNKNOWN\n"
                cons_unknown=1
            elif [ -z "$ap_main_vm" ] || [ -z "$ap_vm_keep" ]; then
                cons_lines="${cons_lines}vm_keep: 计划 ${plan_keep} / 实际 未记录 → UNKNOWN\n"
                cons_unknown=1
            elif [ "$ap_vm_keep" = "yes" ] && [ "$plan_keep" = "yes" ]; then
                cons_lines="${cons_lines}vm_keep: 计划 yes / 实际 yes → PASS\n"
            else
                cons_lines="${cons_lines}vm_keep: 计划 ${plan_keep} / 实际 ${ap_vm_keep} → FAIL\n"
                cons_fail=1
            fi
        else
            cons_lines="${cons_lines}vm_keep: 计划 no（${type} 不追加 --vm-keep）/ 实际 ${ap_vm_keep:-未记录} → 不适用\n"
        fi

        # 4) hdd 实际进程数 = cwd 集合数，并与计划 disk_streams 对照
        #    （hdd_dirs 为逗号拼接的展示字段，不参与计数；peer_disks 只展示）
        if [ "$type_is_hdd" -eq 0 ]; then
            cons_lines="${cons_lines}hdd 进程数: 计划 0（${type} 模式不压盘）/ 实际 ${ap_hdd_n:-未记录} → 不适用\n"
        elif [ "$ap_hdd_n" = "0" ] && ! is_mature_label "$ap_label"; then
            # 60s 快照出现 0 个 hdd 进程多为子进程刚启动的竞态，只判 UNKNOWN
            cons_lines="${cons_lines}hdd 进程数: ${ap_label} 快照实际进程 0（子进程可能刚启动）→ UNKNOWN\n"
            cons_unknown=1
        elif [ -z "$ap_hdd_n" ]; then
            cons_lines="${cons_lines}hdd 进程数: actual-params 缺少 hdd_processes 字段 → UNKNOWN\n"
            cons_unknown=1
        else
            local plan_disk_num=-1
            case "$plan_disk" in
                ''|none)   plan_disk_num=-1 ;;
                *[!0-9]*)  plan_disk_num=-1 ;;
                *)         plan_disk_num=$(( 10#$plan_disk )) ;;
            esac
            if [ "$ap_hdd_n" -ne "$hdd_cwd_n" ]; then
                if [ "$cwd_unknown" -eq 1 ] || [ "$block_hdd_n" -eq 0 ]; then
                    cons_lines="${cons_lines}hdd 进程数: 计划 disk_streams=${plan_disk:-未记录} / 实际进程 ${ap_hdd_n}（cwd 集合 ${hdd_cwd_n}）→ UNKNOWN（cwd 不可用或快照缺 hdd 进程）\n"
                    cons_unknown=1
                else
                    cons_lines="${cons_lines}hdd 进程数: 计划 disk_streams=${plan_disk:-未记录}（peer_disks=${plan_peer:-0} 不参与判定）/ 实际进程 ${ap_hdd_n}（cwd 集合 ${hdd_cwd_n}）→ FAIL（进程数与 cwd 集合数不一致）\n"
                    cons_fail=1
                fi
            elif [ "$plan_disk_num" -lt 0 ]; then
                cons_lines="${cons_lines}hdd 进程数: 计划 disk_streams 未记录 / 实际 ${ap_hdd_n}（cwd 集合 ${hdd_cwd_n}）→ UNKNOWN\n"
                cons_unknown=1
            elif [ "$ap_hdd_n" -ne "$plan_disk_num" ]; then
                cons_lines="${cons_lines}hdd 进程数: 计划 disk_streams=${plan_disk_num}（peer_disks=${plan_peer:-0}，effective=${plan_eff:-未记录} 不参与判定）/ 实际 ${ap_hdd_n}（cwd 集合 ${hdd_cwd_n}）→ FAIL\n"
                cons_fail=1
            else
                cons_lines="${cons_lines}hdd 进程数: 计划 disk_streams=${plan_disk}（peer_disks=${plan_peer:-0}，effective=${plan_eff:-未记录} 不参与判定）/ 实际 ${ap_hdd_n}（cwd 集合 ${hdd_cwd_n}）→ PASS\n"
            fi

            # 5) 每个 hdd cwd 均有效且在同一 cwd 集合内（集合来自快照，保留空格/逗号）
            if [ "$ap_hdd_n" -eq 0 ] && [ "$hdd_cwd_n" -eq 0 ]; then
                cons_lines="${cons_lines}每个 hdd cwd 在 dirs 集合内: 无 hdd 进程 → PASS\n"
            elif [ "$cwd_unknown" -eq 1 ]; then
                cons_lines="${cons_lines}每个 hdd cwd 在 dirs 集合内: hdd cwd 为 ? 或空 → UNKNOWN\n"
                cons_unknown=1
            elif [ -z "$block" ]; then
                cons_lines="${cons_lines}每个 hdd cwd 在 dirs 集合内: 缺少 ${ap_label} 快照 → UNKNOWN\n"
                cons_unknown=1
            else
                local bad_cwds="" ln cmd ln_cwd
                while IFS= read -r ln; do
                    [ -n "$ln" ] || continue
                    cmd=$(snapshot_cmdline "$ln")
                    [ -n "$cmd" ] || continue
                    is_stress_proc "$cmd" || continue
                    case " $cmd " in *" --hdd "*) ;; *) continue ;; esac
                    ln_cwd=$(snapshot_cwd "$ln")
                    case "$ln_cwd" in ''|'?') continue ;; esac
                    case "$nl$hdd_cwd_list$nl" in
                        *"$nl$ln_cwd$nl"*) ;;
                        *) bad_cwds="$bad_cwds $ln_cwd" ;;
                    esac
                done <<< "$block"
                if [ "$block_hdd_n" -eq 0 ]; then
                    cons_lines="${cons_lines}每个 hdd cwd 在 dirs 集合内: 快照缺少 hdd 进程证据 → UNKNOWN\n"
                    cons_unknown=1
                elif [ -n "$bad_cwds" ]; then
                    cons_lines="${cons_lines}每个 hdd cwd 在 dirs 集合内: 集合 ${ap_hdd_dirs} / 越界 ${bad_cwds# } → FAIL\n"
                    cons_fail=1
                else
                    cons_lines="${cons_lines}每个 hdd cwd 在 dirs 集合内: 集合 ${ap_hdd_dirs} → PASS\n"
                fi
            fi
        fi

        # 6) 常驻内存 RSS 总量与计划总量误差 ≤15%（仅 600s/periodic 快照可判）
        if [ "$type_is_mem" -eq 0 ]; then
            cons_lines="${cons_lines}常驻内存 RSS: 不适用（${type} 模式无内存计划）\n"
        elif ! is_mature_label "$ap_label"; then
            cons_lines="${cons_lines}常驻内存 RSS: 仅有 ${ap_label} 快照，不作 15% 判定 → UNKNOWN\n"
            cons_unknown=1
        elif [ -z "$ap_main_vm" ]; then
            cons_lines="${cons_lines}常驻内存 RSS: 实际进程未记录 → UNKNOWN\n"
            cons_unknown=1
        elif [ -z "$plan_vm" ] || [ "$plan_vm" = "none" ]; then
            cons_lines="${cons_lines}常驻内存 RSS: 计划 dimms 未记录 → UNKNOWN\n"
            cons_unknown=1
        elif [ -z "$plan_per_mb" ] || [ "$plan_per_mb" = "none" ]; then
            cons_lines="${cons_lines}常驻内存 RSS: 计划 per_worker_mb 未记录 → UNKNOWN\n"
            cons_unknown=1
        else
            local plan_vm_num=0 plan_per_num=0
            case "$plan_vm" in ''|*[!0-9]*) ;; *) plan_vm_num=$(( 10#$plan_vm )) ;; esac
            case "$plan_per_mb" in ''|*[!0-9]*) ;; *) plan_per_num=$(( 10#$plan_per_mb )) ;; esac
            planned_kb=$(( plan_vm_num * plan_per_num * 1024 ))
            if [ "$planned_kb" -le 0 ]; then
                # 兜底：从“命令:”解析 --vm / --vm-bytes
                local c_vm c_bytes c_mb
                c_vm=$(printf '%s' "$rc_cmd" | sed -n 's/.*--vm[[:space:]][[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)
                c_bytes=$(printf '%s' "$rc_cmd" | sed -n 's/.*--vm-bytes[[:space:]][[:space:]]*\([0-9][0-9KkMmGgTt]*\).*/\1/p' | head -1)
                c_mb=$(parse_size_mb "$c_bytes")
                case "$c_vm" in ''|*[!0-9]*) c_vm=0 ;; esac
                case "$c_mb" in ''|*[!0-9]*) c_mb=0 ;; esac
                planned_kb=$(( c_vm * c_mb * 1024 ))
            fi
            if [ "$planned_kb" -le 0 ]; then
                cons_lines="${cons_lines}常驻内存 RSS: 计划总量无法解析 → UNKNOWN\n"
                cons_unknown=1
            elif [ -z "$block" ]; then
                cons_lines="${cons_lines}常驻内存 RSS: 计划 ${planned_kb} kB / 实际 缺少 ${ap_label} 快照 → UNKNOWN\n"
                cons_unknown=1
            elif ! printf '%s\n' "$block" | grep -q 'rss_kb='; then
                cons_lines="${cons_lines}常驻内存 RSS: 快照缺少 rss_kb 字段 → UNKNOWN\n"
                cons_unknown=1
            else
                local actual_rss diff pct
                actual_rss=$(printf '%s\n' "$block" | awk 'match($0, / rss_kb=[0-9]+/){v=substr($0,RSTART+8,RLENGTH-8); s+=v} END{printf "%d", s+0}')
                if [ "$actual_rss" -le 0 ]; then
                    cons_lines="${cons_lines}常驻内存 RSS: 实际 RSS 未记录 → UNKNOWN\n"
                    cons_unknown=1
                else
                    diff=$(( actual_rss - planned_kb )); [ "$diff" -lt 0 ] && diff=$(( -diff ))
                    pct=$(( diff * 100 / planned_kb ))
                    if [ "$pct" -le 15 ]; then
                        cons_lines="${cons_lines}常驻内存 RSS: 计划 ${planned_kb} kB / 实际 ${actual_rss} kB（偏差 ${pct}%）→ PASS\n"
                    else
                        cons_lines="${cons_lines}常驻内存 RSS: 计划 ${planned_kb} kB / 实际 ${actual_rss} kB（偏差 ${pct}%）→ FAIL\n"
                        cons_fail=1
                    fi
                fi
            fi
        fi
    fi

    # 汇总判定：FAIL 优先；UNKNOWN 仅提示，不改变既有结论。
    # 仅当原结论仍为“正常”时才改写为执行不一致；已异常/已停止保留原结论与优先级。
    if [ "$cons_fail" -eq 1 ]; then
        cons_status="FAIL"
        if [ "$conclusion" = "正常" ]; then
            conclusion="异常（执行与计划不一致）"
            is_bad=1
        else
            cons_conflict=1
        fi
    elif [ "$cons_unknown" -eq 1 ]; then
        cons_status="UNKNOWN"
    else
        cons_status="PASS"
    fi

    # 生成 summary.txt 并打印
    {
        echo "==== 压测复盘总结 ===="
        echo "结论: $conclusion"
        if [ "$is_bad" -eq 1 ]; then
            echo "异常点:"
            if [ "$pids_count" -gt "$ec_count" ]; then
                echo "  退出码文件缺失（pids 数 ${pids_count} vs exitcode 数 ${ec_count}）"
            fi
            for ec in "$dir"/*.exitcode; do
                [ -f "$ec" ] || continue
                code=$(cat "$ec" 2>/dev/null)
                [ "$code" != "0" ] && echo "  $(basename "$ec") = ${code}"
            done
            if [ "$err_hit" -eq 1 ]; then
                echo "  error.log 命中（前 3 条）:"
                grep -E '检测到 stress|dmesg' "$dir/error.log" 2>/dev/null | head -3 | sed 's/^/    /'
            fi
            if [ "$un_n" -gt 0 ]; then
                echo "  未归因内核 I/O 错误 ${un_n} 条（error-unattributed.log，不计入本盘结论）"
            fi
        fi
        echo "生成时间: $(now)"
        echo "结果目录: $dir"
        echo "类型: $type"
        echo "机型: $model"
        # 系统盘口径（FR-10）：run-config 中存在的覆盖边界说明原样回显
        grep -h '^压测对象:' "$dir/run-config.txt" 2>/dev/null
        grep -h '^覆盖边界:' "$dir/run-config.txt" 2>/dev/null
        echo "开始时间: $start_time"
        echo "计划超时: $plan_timeout"
        echo "预计结束时间: ${end_est:-未知}（按监控覆盖时长估算）"
        echo "监控采样行数: $rows"
        echo "监控覆盖时长: ${duration} 秒（间隔 ${interval} 秒）"
        if [ -f "$dir/status.txt" ]; then
            echo "运行状态: ${state}（${reason}）"
            echo "OOM: $([ "$oom_field" = "yes" ] && echo 是 || echo 否)"
        else
            echo "运行状态: 未记录（无 status.txt）"
        fi
        # 未归因内核 I/O 错误：正常结论也显式提示（未归因不改结论）
        if [ "$is_bad" -ne 1 ] && [ "$un_n" -gt 0 ]; then
            echo "未归因内核 I/O 错误 ${un_n} 条（error-unattributed.log，不计入本盘结论）"
        fi
        echo "采样空洞: ${hole}"
        echo "CPU 使用率: 均值 ${cpu_mean}%，峰值 ${cpu_max}%"
        echo "内存峰值 (mem_used): ${mem_max} kB"
        echo "磁盘读峰值: ${rd_max} MB/s"
        echo "磁盘写峰值: ${wr_max} MB/s"
        echo ""
        echo "== 退出码 =="
        local ec_files=("$dir"/*.exitcode)
        if [ -e "${ec_files[0]}" ]; then
            for f in "${ec_files[@]}"; do
                [ -f "$f" ] || continue
                echo "$(basename "$f"): $(cat "$f")"
            done
        else
            echo "未找到退出码文件（可能仍在运行或未执行）"
        fi
        echo "（0 表示 stress 正常结束，非 0 表示异常或被中断）"
        echo ""
        echo "== 错误日志 =="
        if [ -f "$dir/error.log" ]; then
            err_lines=$(wc -l < "$dir/error.log")
            echo "error.log 共 ${err_lines} 行"
            if [ "$err_lines" -gt 1 ]; then head -20 "$dir/error.log" | sed 's/^/  /'; fi
        else
            echo "未生成错误日志（旧版本目录）"
        fi
        echo ""
        echo "== 执行一致性 =="
        echo "结论: $cons_status"
        printf '%b' "$cons_lines" | sed 's/^/  /'
        [ "$cons_conflict" -eq 1 ] && echo "执行一致性: FAIL（详见本节）"
        echo ""
        echo "原始数据: monitor.csv / run-config.txt / info-before.txt / stress*.log / error.log / runtime-snapshot.txt / actual-params.txt"
    } > "$dir/summary.txt"
    cat "$dir/summary.txt"
}

# ---------- snapshot（手动抓取运行时证据） ----------

cmd_snapshot() {
    local dir="${1:-}"
    [ -n "$dir" ] || { echo "用法: stress-test.sh snapshot <结果目录>"; exit 1; }
    [ -d "$dir" ] || { echo "结果目录不存在：$dir"; exit 1; }
    runtime_snapshot "$dir" manual
    echo "已写入运行快照：$dir/runtime-snapshot.txt"
    [ -f "$dir/actual-params.txt" ] && echo "实际参数：$dir/actual-params.txt"
}
