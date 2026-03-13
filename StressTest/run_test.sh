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

log_dir="$LOG_ROOT/run_$(now_ts)"
mkdir -p "$log_dir"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$log_dir/run.log"; }

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    log "ERROR: missing binary: $1"; exit 1; }
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
"GPU" "gpu_burn" OFF \
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
"\"GPU\"") RUN_GPU=1 ;;
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
"GPU" "gpu_burn -tc" off \
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
"\"GPU\"") RUN_GPU=1 ;;
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

# ======= GPU burn =======

if [ $RUN_GPU -eq 1 ]; then

log "Running gpu_burn for ${GPU_BURN_SECS}s"

if [ -n "$GPU_BURN_DIR" ]; then
( cd "$GPU_BURN_DIR" && "$GPU_BURN_BIN" -tc "$GPU_BURN_SECS" ) \
2>&1 | tee "$log_dir/gpu_burn.log"
else
"$GPU_BURN_BIN" -tc "$GPU_BURN_SECS" \
2>&1 | tee "$log_dir/gpu_burn.log"
fi

fi

# ======= Field diagnostics =======

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

# ======= CPU stress =======

if [ $RUN_CPU -eq 1 ]; then

log "Running CPU stress-ng for ${CPU_STRESS_SECS}s"

"$STRESS_NG_BIN" \
--cpu 0 \
--cpu-method all \
--timeout "${CPU_STRESS_SECS}s" \
--metrics-brief \
2>&1 | tee "$log_dir/cpu_stress.log"

fi

# ======= MEM stress =======

if [ $RUN_MEM -eq 1 ]; then

log "Running MEM stress-ng for ${MEM_STRESS_SECS}s"

"$STRESS_NG_BIN" \
--vm 0 \
--vm-bytes 95% \
--timeout "${MEM_STRESS_SECS}s" \
--metrics-brief \
2>&1 | tee "$log_dir/mem_stress.log"

fi

# ======= Disk test =======

if [ $RUN_DISK -eq 1 ]; then

log "Detecting NVMe devices..."

# 自动检测所有 PCIe NVMe 磁盘
NVME_DEVS=$(lsblk -d -n -o NAME,TYPE | awk '$2=="disk" && $1 ~ /^nvme/ {print "/dev/"$1}')

if [ -z "$NVME_DEVS" ]; then
    log "WARN: No NVMe devices detected. Skipping disk test."
else
    log "NVMe devices detected:"
    for dev in $NVME_DEVS; do
        log "  $dev"
    done

    log "Running fio disk test for ${DISK_TEST_SECS}s"

    # AI 服务器推荐参数（高负载）
    fio_cmd=(
        "$FIO_BIN"
        --rw=randrw           # 随机读写
        --rwmixread=70        # 70% 读
        --bs=4k               # 4KB 块大小
        --ioengine=libaio     # 异步 IO
        --direct=1            # 绕过操作系统缓存
        --thread              # 使用线程模式
        --numjobs=4           # 每个设备 4 个线程 job
        --iodepth=64          # 队列深度 64
        --randrepeat=0        # 每次随机不同
        --invalidate=1        # 清空缓存影响
        --norandommap         # 减少内存占用
        --time_based
        --runtime="$DISK_TEST_SECS"
        --group_reporting
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


