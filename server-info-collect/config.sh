#!/bin/bash

# Get system serial number
SERVER_SN=$(dmidecode -s system-serial-number 2>/dev/null | tr -d ' ')

if [ -z "$SERVER_SN" ] || [[ "$SERVER_SN" == "Not"* ]]; then
    SERVER_SN=$(hostname)
fi

OUTPUT_FILE="${SERVER_SN}.txt"
{
echo "================ SERVER ================"
echo "Server SN: $SERVER_SN"
echo "Hostname: $(hostname)"
echo "Date: $(date)"
echo ""

echo "================ CPU ================="

CPU_MODEL=$(lscpu | awk -F: '/Model name/ {gsub(/^[ \t]+/,"",$2); print $2}')

CPU_SOCKETS=$(lscpu | awk -F: '/Socket\(s\)/ {gsub(/ /,"",$2); print $2}')

CPU_CORES=$(lscpu | awk -F: '/Core\(s\) per socket/ {gsub(/ /,"",$2); print $2}')

CPU_ID=$(dmidecode -t processor | awk -F: '/ID:/ {print $2; exit}')

CPU_FREQ=$(lscpu | awk '/CPU max MHz/ {print $4}')

[ -z "$CPU_FREQ" ] && CPU_FREQ=$(lscpu | awk '/CPU MHz/ {print $3}' | head -1)

[ -z "$CPU_FREQ" ] && CPU_FREQ="Unknown"

echo "CPU型号: $CPU_MODEL"
echo "CPU数量: $CPU_SOCKETS"
echo "每颗CPU核心: $CPU_CORES"
echo "CPU主频(MHz): $CPU_FREQ"
echo "CPU ID: $CPU_ID"

echo ""
echo "================ Memory ================="

TOTAL_MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
TOTAL_MEM_T=$(awk "BEGIN {printf \"%.2f\", $TOTAL_MEM_KB/1024/1024/1024}")

echo "Total Memory (TB): $TOTAL_MEM_T"
echo ""

echo "Memory Modules:"

dmidecode -t memory | awk '
/Memory Device/ {size=""; speed=""; sn=""; vendor=""}

/Size:/ {if ($2!="No") size=$2" "$3}

/Speed:/ {speed=$2" "$3}

/Manufacturer:/ {vendor=$2}

/Serial Number:/ {
sn=$3
if(size!=""){
printf("Vendor:%s  Size:%s  Speed:%s  SN:%s\n",vendor,size,speed,sn)
}
}'

echo ""
echo "================ 硬盘 ================="

echo "NVMe硬盘:"
if command -v nvme >/dev/null; then

COUNT=0

nvme list | awk 'NR>2 {
print "厂家/型号:",$3,$4,"容量:",$5,$6,"SN:",$2
count++
} END {print "NVMe数量:",count}'

else
echo "nvme-cli 未安装"
fi

echo ""
echo "SATA / SAS硬盘:"
lsblk -d -o NAME,SIZE,MODEL,VENDOR,TRAN | grep -v loop

echo ""
echo "================ GPU ================="

if command -v nvidia-smi >/dev/null; then
nvidia-smi --query-gpu=name,memory.total,power.limit,serial \
--format=csv,noheader,nounits | while IFS=',' read name mem power sn
do
echo "型号:$name 显存:${mem}MB 功率:${power}W SN:$sn"
done
else
echo "未检测到 NVIDIA GPU"
fi

echo ""
echo "================ 网卡 ================="

for iface in $(ls /sys/class/net | grep -v lo); do

    PCI=$(ethtool -i $iface 2>/dev/null | awk '/bus-info/ {print $2}')
    DRIVER=$(ethtool -i $iface 2>/dev/null | awk '/driver/ {print $2}')
    MODEL=$(lspci -s $PCI 2>/dev/null | cut -d':' -f3)

    # 默认速率
    SPEED=$(ethtool $iface 2>/dev/null | awk '/Speed:/ {print $2}')

    # InfiniBand接口或者未知速率使用ibstat
    if [[ $iface == ib* ]] || [[ "$SPEED" == "Unknown!" ]]; then
        SPEED=$(ibstat 2>/dev/null | awk '/Rate:/ {print $2,$3; exit}')
    fi

    # 默认 SN / MAC
    SN="N/A"
    MAC=$(cat /sys/class/net/$iface/address 2>/dev/null)

    # Mellanox网卡尝试读取真实SN
    if [[ "$MODEL" == *Mellanox* ]] || [[ "$MODEL" == *NVIDIA* ]]; then
        SN=$(mlxconfig -d $PCI q 2>/dev/null | awk -F ':' '/Serial Number/ {print $2}' | xargs)
    fi

    echo "接口: $iface"
    echo "厂家/型号: $MODEL"
    echo "驱动: $DRIVER"
    echo "PCI: $PCI"
    echo "速率: ${SPEED:-Unknown}"
    
    # Ethernet接口显示MAC
    if [[ "$iface" == eth* ]]; then
        echo "MAC: $MAC"
    fi

    # 显示SN，如果有
    if [[ "$SN" != "N/A" ]]; then
        echo "SN: $SN"
    fi

    echo ""

done

echo ""
echo "================ RAID / 阵列卡 ================="

RAID=$(lspci | grep -Ei "raid|storage|sas")

if [ -z "$RAID" ]; then
echo "RAID卡: 无"
else
echo "$RAID"
fi

echo ""
echo "================ 系统 ================="

uname -r
lsb_release -d 2>/dev/null

} > "$OUTPUT_FILE"

echo ""
echo "硬件信息已保存到: $OUTPUT_FILE"
