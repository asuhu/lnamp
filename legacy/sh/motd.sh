#!/usr/bin/env bash

mapfile -t DFH < <(df -h -x zfs -x squashfs -x tmpfs -x devtmpfs -x overlay --output=target,pcent,size,used | tail -n+2)

# Colors
G="\033[01;32m"
R="\033[01;31m"
D="\033[39m\033[2m"
N="\033[0m"

# Get load averages
LOAD1=$(grep "" /proc/loadavg | awk '{print $1}')
LOAD5=$(grep "" /proc/loadavg | awk '{print $2}')
LOAD15=$(grep "" /proc/loadavg | awk '{print $3}')

# Get free memory
MEMORY_USED=$(free -t -m | grep "Mem" | awk '{print $3}')
MEMORY_ALL=$(free -t -m | grep "Mem" | awk '{print $2}')
MEMORY_PERCENTAGE=$(free | awk '/Mem/{printf("%.2f%"), $3/$2*100}')
echo
echo -e "  SYSTEM    : $(cat /etc/redhat-release)"
echo -e "  MEMORY    : ${MEMORY_USED} MB / ${MEMORY_ALL} MB (${G}${MEMORY_PERCENTAGE}${N} Used)"
echo -e "  LOAD AVG  : ${G}${LOAD1}${N} (1m), ${G}${LOAD5}${N} (5m), ${G}${LOAD15}${N} (15m)"
echo


for LINE in "${DFH[@]}"; do
    # Get disk usage
    DISK_USAGE=$(echo "${LINE}" | awk '{print $2}' | sed 's/%//')
    USAGE_WIDTH=$(((${DISK_USAGE}*60)/100))

    # If the usage rate is <90%, the color is green, otherwise it is red
    if [ "${DISK_USAGE}" -gt 90 ]; then
        COLOR="${R}"
    else
        COLOR="${G}"
    fi

    # Print the used width
    BAR="[${COLOR}"
    for ((i=0; i<"${USAGE_WIDTH}"; i++)); do
        BAR+="="
    done

    # Print unused width
    BAR+=${D}
    for ((i="${USAGE_WIDTH}"; i<60; i++)); do
        BAR+="="
    done
    BAR+="${N}]"

    # Output
    echo "${LINE}" | awk '{ printf("Mounted: %-28s %s / %s (%s Used)\n", $1, $4, $3, $2); }' | sed -e 's/^/  /'
    echo -e "${BAR}" | sed -e 's/^/  /'
done
echo
