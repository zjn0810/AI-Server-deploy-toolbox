#!/usr/bin/env bash

# ======= Config =======
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config/config.conf"

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
else
    echo "ERROR: config file not found: $CONFIG_FILE" >&2
    exit 1
fi

# ======= Helpers =======
now_ts() { date '+%Y%m%d_%H%M%S'; }

SN=$(cat /sys/class/dmi/id/product_serial 2>/dev/null)
if [[ -z "$SN" ]]; then
        SN=$(dmidecode -s system-serial-number 2>/dev/null)
fi

SN=${SN:-UNKNOWN}
SN=${SN// /_}


log_dir="$LOG_ROOT/stress_${SN}_$(now_ts)"
mkdir -p "$log_dir"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$log_dir/run.log"; }

require_bin() {
    command -v "$1" >/dev/null 2>&1 || {
        log "ERROR: missing binary: $1"
        exit 1
    }
}

# ======= Test selection =======
RUN_GPU=0
RUN_CPU=0
RUN_MEM=0
RUN_DISK=0
RUN_FIELDIAG_L1=0
RUN_FIELDIAG_L2=0

select_tests() {

    if [ -t 1 ] && command -v dialog >/dev/null 2>&1; then
        choices=$(dialog --clear --title "Burn-in Tests" --checklist \
        "Select tests to run (SPACE toggle, ENTER confirm)" 20 78 10 \
        "GPU_BURN" "gpu_burn" OFF \
        "FIELDIAG_L1" "fieldiag --level1 --no_bmc" OFF \
        "FIELDIAG_L2" "fieldiag --level2 --no_bmc" OFF \
        "CPU" "stress-ng cpu" OFF \
        "MEM" "stress-ng mem" OFF \
        "DISK" "fio randrw" OFF \
        3>&1 1>&2 2>&3)
        exit_status=$?
        clear

        RUN_GPU=0
        RUN_CPU=0
        RUN_MEM=0
        RUN_DISK=0
        RUN_FIELDIAG_L1=0
        RUN_FIELDIAG_L2=0

        for item in $choices; do
            case "$item" in
                "\"GPU_BURN\"") RUN_GPU=1 ;;
                "\"FIELDIAG_L1\"") RUN_FIELDIAG_L1=1 ;;
                "\"FIELDIAG_L2\"") RUN_FIELDIAG_L2=1 ;;
                "\"CPU\"") RUN_CPU=1 ;;
                "\"MEM\"") RUN_MEM=1 ;;
                "\"DISK\"") RUN_DISK=1 ;;
            esac
        done

    elif [ -t 1 ] && command -v whiptail >/dev/null 2>&1; then
        choices=$(whiptail --title "Burn-in Tests" --checklist \
        "Select tests to run (SPACE toggle, ENTER confirm)" 20 78 10 \
        "GPU_BURN" "gpu_burn -tc" off \
        "FIELDIAG_L1" "fieldiag --level1 --no_bmc" off \
        "FIELDIAG_L2" "fieldiag --level2 --no_bmc" off \
        "CPU" "stress-ng cpu" off \
        "MEM" "stress-ng mem" off \
        "DISK" "fio randrw" off \
        3>&1 1>&2 2>&3)

        exit_status=$?
        if [ $exit_status -ne 0 ]; then
            echo "Selection cancelled."
            exit 1
        fi

        RUN_GPU=0
        RUN_CPU=0
        RUN_MEM=0
        RUN_DISK=0
        RUN_FIELDIAG_L1=0
        RUN_FIELDIAG_L2=0

        for item in $choices; do
            case "$item" in
                "\"GPU_BURN\"") RUN_GPU=1 ;;
                "\"FIELDIAG_L1\"") RUN_FIELDIAG_L1=1 ;;
                "\"FIELDIAG_L2\"") RUN_FIELDIAG_L2=1 ;;
                "\"CPU\"") RUN_CPU=1 ;;
                "\"MEM\"") RUN_MEM=1 ;;
                "\"DISK\"") RUN_DISK=1 ;;
            esac
        done

    else
        echo "Select tests (comma separated)"
        echo "gpu,fieldiag1,fieldiag2,cpu,mem,disk"
        echo "Default: gpu,fieldiag2,cpu,mem,disk"
        read -r -p "Tests> " input

        if [ -n "$input" ]; then
            RUN_GPU=0
            RUN_CPU=0
            RUN_MEM=0
            RUN_DISK=0
            RUN_FIELDIAG_L1=0
            RUN_FIELDIAG_L2=0

            IFS=',' read -r -a parts <<< "$input"
            for p in "${parts[@]}"; do
                case "$(echo "$p" | tr '[:upper:]' '[:lower:]' | xargs)" in
                    gpu) RUN_GPU=1 ;;
                    fieldiag1) RUN_FIELDIAG_L1=1 ;;
                    fieldiag2) RUN_FIELDIAG_L2=1 ;;
                    cpu) RUN_CPU=1 ;;
                    mem) RUN_MEM=1 ;;
                    disk) RUN_DISK=1 ;;
                esac
            done
        fi
    fi

    # ======= Mutual exclusion check =======
    if [ $RUN_FIELDIAG_L1 -eq 1 ] && [ $RUN_FIELDIAG_L2 -eq 1 ]; then
        echo "ERROR: FIELDIAG level1 and level2 cannot both be selected."
        exit 1
    fi

    if [ $RUN_GPU -eq 0 ] && \
       [ $RUN_CPU -eq 0 ] && \
       [ $RUN_MEM -eq 0 ] && \
       [ $RUN_DISK -eq 0 ] && \
       [ $RUN_FIELDIAG_L1 -eq 0 ] && \
       [ $RUN_FIELDIAG_L2 -eq 0 ]; then
        echo "No tests selected. Exiting."
        exit 1
    fi
}

select_tests

# ======= Preflight =======
log "Starting full burn-in..."
log "Logs: $log_dir"

if [ $RUN_CPU -eq 1 ] || [ $RUN_MEM -eq 1 ]; then
    require_bin "$STRESS_NG_BIN"
fi

if [ $RUN_GPU -eq 1 ]; then
    require_bin "$GPU_BURN_BIN"
fi

if [ $RUN_DISK -eq 1 ]; then
    require_bin "$FIO_BIN"
fi

if { [ $RUN_FIELDIAG_L1 -eq 1 ] || [ $RUN_FIELDIAG_L2 -eq 1 ]; } && \
   ! command -v "$FIELDIAG_BIN" >/dev/null 2>&1; then
    log "WARN: fieldiag not found: $FIELDIAG_BIN (skip)"
    FIELDIAG_BIN=""
fi

# ======= GPU burn ============================================================================
log "Running gpu_burn for ${GPU_BURN_SECS}s"

MONITOR_SCRIPT="/opt/AI-Server-deploy-toolbox/StressTest/monitor/slowdown.sh"

# ===== 启动监控（提前10分钟结束）=====
MONITOR_SECS=$((GPU_BURN_SECS * 19 / 20))
if (( MONITOR_SECS < 0 )); then
    MONITOR_SECS=$GPU_BURN_SECS
fi

log "Starting GPU monitor for ${MONITOR_SECS}s"

# 启动监控（后台）
bash "$MONITOR_SCRIPT" "$MONITOR_SECS" > "$log_dir/monitor.log" 2>&1 &
MONITOR_PID=$!

log "Monitor PID: $MONITOR_PID"

# ===== 启动 gpu_burn =====
if [ -n "$GPU_BURN_DIR" ]; then
    ( cd "$GPU_BURN_DIR" && "$GPU_BURN_BIN" -tc "$GPU_BURN_SECS" ) \
    2>&1 | tee "$log_dir/gpu_burn.log" &
else
    "$GPU_BURN_BIN" -tc "$GPU_BURN_SECS" \
    2>&1 | tee "$log_dir/gpu_burn.log" &
fi

GPU_BURN_PID=$!
log "gpu_burn PID: $GPU_BURN_PID"

# ===== 等待 gpu_burn =====
wait $GPU_BURN_PID
GPU_BURN_RC=$?

log "gpu_burn finished with code: $GPU_BURN_RC"

# ===== 关键：停止监控 =====
if ps -p $MONITOR_PID >/dev/null 2>&1; then
    log "Stopping monitor (PID $MONITOR_PID)..."
    kill $MONITOR_PID
    wait $MONITOR_PID 2>/dev/null
fi

# ===== 判断结果 =====
if [ $GPU_BURN_RC -ne 0 ]; then
    log "ERROR: gpu_burn failed!"
else
    log "gpu_burn completed successfully"
fi
# ======= Field diagnostics ==================================================================
if [ $RUN_FIELDIAG_L1 -eq 1 ] && [ -n "$FIELDIAG_BIN" ]; then
    log "Running fieldiag --level1 --no_bmc"
    if [ -n "$FIELDIAG_DIR" ]; then
        ( cd "$FIELDIAG_DIR" && "$FIELDIAG_BIN" --level1 --no_bmc ) \
        2>&1 | tee "$log_dir/fieldiag.log"
    else
        "$FIELDIAG_BIN" --level1 --no_bmc \
        2>&1 | tee "$log_dir/fieldiag.log"
    fi
fi

if [ $RUN_FIELDIAG_L2 -eq 1 ] && [ -n "$FIELDIAG_BIN" ]; then
    log "Running fieldiag --level2 --no_bmc"
    if [ -n "$FIELDIAG_DIR" ]; then
        ( cd "$FIELDIAG_DIR" && "$FIELDIAG_BIN" --level2 --no_bmc ) \
        2>&1 | tee "$log_dir/fieldiag.log"
    else
        "$FIELDIAG_BIN" --level2 --no_bmc \
        2>&1 | tee "$log_dir/fieldiag.log"
    fi
fi

# ======= CPU stress ========================================================================
if [ $RUN_CPU -eq 1 ]; then
    log "Running CPU stress-ng for ${CPU_STRESS_SECS}s"
    "$STRESS_NG_BIN" \
        --cpu 0 \
        --cpu-method all \
        --timeout "${CPU_STRESS_SECS}s" \
        --metrics-brief \
        2>&1 | tee "$log_dir/cpu_stress.log"
fi

# ======= MEM stress =======================================================================
if [ $RUN_MEM -eq 1 ]; then
    log "Running MEM stress-ng for ${MEM_STRESS_SECS}s"
    "$STRESS_NG_BIN" \
        --vm 0 \
        --vm-bytes 95% \
        --timeout "${MEM_STRESS_SECS}s" \
        --metrics-brief \
        2>&1 | tee "$log_dir/mem_stress.log"
fi

# ======= Disk test =========================================================================
if [ $RUN_DISK -eq 1 ]; then
    log "Detecting NVMe devices..."
    NVME_DEVS=$(lsblk -d -n -o NAME,TYPE | awk '$2=="disk" && $1 ~ /^nvme/ {print "/dev/"$1}')

    if [ -z "$NVME_DEVS" ]; then
        log "WARN: No NVMe devices detected. Skipping disk test."
    else
        log "NVMe devices detected:"
        for dev in $NVME_DEVS; do
            log "  $dev"
        done

        log "Running fio disk test for ${DISK_TEST_SECS}s"

        fio_cmd=(
            "$FIO_BIN"
            --rw=randrw           # I/O 模式：随机读写混合 (random read/write)，模拟真实业务负载
            --rwmixread=70        # 读写比例：70% 读 / 30% 写（很多数据库、AI推理场景接近这种比例）

            --bs=4k               # I/O 块大小：4KB
                                  # 这是最常见的小块随机IO尺寸，用于测试IOPS能力
			
            --size=100%		  #覆盖整个盘空间,防止只测到一小部分 NAND

            --ioengine=io_uring   # IO引擎：Linux 新一代异步IO接口 io_uring
                                  # 相比 libaio：
                                  # 1. 延迟更低
                                  # 2. 并发能力更强
                                  # 3. 新内核 NVMe 推荐使用

            --direct=1            # Direct I/O：绕过操作系统 Page Cache
                                  # 保证测试的是“硬盘真实性能”，而不是内存缓存

            --thread              # 使用线程模式而不是进程模式
                                  # 在高并发IO测试时线程开销更小

            --numjobs=8           # 每个设备启动 8 个并发 job
                                  # 相当于 8 个 worker 同时向设备发起IO

            --iodepth=128         # IO 队列深度
                                  # 表示每个 job 同时挂起 128 个 IO 请求
                                  # NVMe 通常需要较高队列深度才能跑满性能

            --randrepeat=0        # 每次运行生成不同的随机序列
                                  # 避免测试结果被缓存或模式化影响

            --invalidate=1        # 在测试开始前清空设备缓存
                                  # 防止历史数据影响测试结果

            --norandommap         # 不记录随机块映射表
                                  # 可以减少 fio 内存占用
                                  # 在大容量 NVMe 测试时非常有用

            --time_based          # 使用时间模式运行测试
                                  # 而不是执行固定IO数量

            --runtime="$DISK_TEST_SECS"   # 测试运行时长（秒）
                                          # 由脚本变量控制

            --group_reporting     # 汇总所有 job 的统计信息
                                  # 输出总 IOPS / 总带宽 / 总延迟
        )

        idx=0
        for dev in $NVME_DEVS; do
            if [ ! -b "$dev" ]; then
                log "WARN: device not found or invalid: $dev, skipping..."
                continue
            fi
            fio_cmd+=(--name="nvme${idx}" --filename="$dev")
            idx=$((idx+1))
        done

        if [ "$idx" -eq 0 ]; then
            log "ERROR: No valid NVMe devices available for testing."
        else
            "${fio_cmd[@]}" 2>&1 | tee "$log_dir/disk_fio.log"
        fi
    fi
fi

log "All tests completed."
log "Logs stored in: $log_dir"

