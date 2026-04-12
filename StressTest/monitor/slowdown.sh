#!/usr/bin/env bash

# =========================
# GPU Stable Monitor v3
# =========================

GPU_BURN_SECS="${1:-0}"

if (( GPU_BURN_SECS <= 0 )); then
    echo "[ERROR] GPU_BURN_SECS invalid"
    exit 1
fi

echo "[INFO] Monitor run ${GPU_BURN_SECS}s"

GPU_COUNT=$(nvidia-smi -L | wc -l)

SN=$(cat /sys/class/dmi/id/product_serial 2>/dev/null)
if [[ -z "$SN" ]]; then
	SN=$(dmidecode -s system-serial-number 2>/dev/null)
fi

SN=${SN:-UNKNOWN}
SN=${SN// /_}

LOG_DIR="logs/slow_${SN}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR"

START_TIME=$(date +%s)

# =========================
# 主循环
# =========================
while true; do

  NOW=$(date +%s)
  ELAPSED=$((NOW - START_TIME))

  if (( ELAPSED >= GPU_BURN_SECS )); then
    echo "[INFO] Monitoring finished"
    break
  fi

  REMAIN=$((GPU_BURN_SECS - ELAPSED))
  TS=$(date '+%F %T')

  HEADER="${TS} | GPU | SN | TempC | PowerW | SMClock | Util% | SWPowerCap | HWSlow | HWThermal | HWBrake | SWThermal | Remain:${REMAIN}s"

  echo "$HEADER"
  echo "$HEADER" >> "$ALL_LOG"

  # =========================
  # 单次稳定query 
  # =========================
  DATA=$(nvidia-smi \
    --query-gpu=index,serial,temperature.gpu,power.draw,clocks.sm,utilization.gpu,\
clocks_throttle_reasons.sw_power_cap,\
clocks_throttle_reasons.hw_slowdown,\
clocks_throttle_reasons.hw_thermal_slowdown,\
clocks_throttle_reasons.hw_power_brake_slowdown,\
clocks_throttle_reasons.sw_thermal_slowdown \
    --format=csv,noheader,nounits 2>/dev/null)

  # =========================
  # 过滤掉 error/help 
  # =========================
  echo "$DATA" | grep -vE "ERROR|Invalid|Option|nvidia-smi" | \
  while IFS=',' read -r IDX SN TEMP POWER CLOCK UTIL SWCAP HWSLOW HWTHERM HWBRAKE SWTEMP; do

    # trim
    SN=$(echo "$SN" | xargs)

    LINE="${TS} | GPU${IDX} | ${SN} | ${TEMP} | ${POWER} | ${CLOCK} | ${UTIL} | ${SWCAP} | ${HWSLOW} | ${HWTHERM} | ${HWBRAKE} | ${SWTEMP}"

    echo "$LINE"
    echo "$LINE" >> "$ALL_LOG"

    # =========================
    # Active 判定
    # =========================
    if [[ "$HWSLOW" == "Active" || \
          "$HWTHERM" == "Active" || \
          "$HWBRAKE" == "Active" || \
          "$SWTEMP" == "Active" ]]; then

      echo "$LINE" >> "$ACTIVE_LOG"
      echo "[ALERT] GPU${IDX} slowdown ACTIVE"
    fi

  done

  sleep 1
  echo ""

done
