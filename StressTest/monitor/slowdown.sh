#!/usr/bin/env bash

# 必须有参数（不加 default）
GPU_BURN_SECS="$1"

echo "[INFO] Monitor will run for ${GPU_BURN_SECS} seconds"

GPU_COUNT=$(nvidia-smi -L | wc -l)

ALL_LOG="slow.log"
ACTIVE_LOG="Active.log"

for ((i=0; i<GPU_BURN_SECS; i++)); do

  TS=$(date '+%F %T')

  HEADER="${TS} | GPU | SN | TempC | PowerW | SMClockMHz | Util% | Idle | SW Power Cap | HW Slowdown | HW Thermal Slowdown | HW Power Brake Slowdown | SW Thermal Slowdown | Remain:$((GPU_BURN_SECS-i))s"

  echo "$HEADER"
  echo "$HEADER" >> "$ALL_LOG"

  for ((g=0; g<GPU_COUNT; g++)); do

    read -r TEMP POWER CLOCK UTIL IDLE SWCAP HWSLOW HWTHERM HWBRAKE SWTHERM < <(
      nvidia-smi -i "$g" \
      --query-gpu=temperature.gpu,power.draw,clocks.sm,utilization.gpu,\
			clocks_throttle_reasons.idle,\
			clocks_throttle_reasons.sw_power_cap,\
			clocks_throttle_reasons.hw_slowdown,\
			clocks_throttle_reasons.hw_thermal_slowdown,\
			clocks_throttle_reasons.hw_power_brake_slowdown,\
			clocks_throttle_reasons.sw_thermal_slowdown \
      --format=csv,noheader,nounits
    )

    LINE="${TS} | GPU${g} | ${TEMP} | ${POWER} | ${CLOCK} | ${UTIL} | Idle:${IDLE} | SWCAP:${SWCAP} | HWSLOW:${HWSLOW} | HWTHERM:${HWTHERM} | HWBRAKE:${HWBRAKE} | SWTHERM:${SWTHERM}"

    echo "$LINE"
    echo "$LINE" >> "$ALL_LOG"

    # 只判断关键字段
    if [[ "$HWSLOW" == "Active" || "$HWTHERM" == "Active" || "$HWBRAKE" == "Active" || "$SWTHERM" == "Active" ]]; then
      echo "$LINE" >> "$ACTIVE_LOG"
      echo "[ALERT] GPU${g} throttle detected!"
    fi

  done

  sleep 1
done
