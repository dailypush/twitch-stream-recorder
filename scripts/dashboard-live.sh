#!/bin/bash

# Twitch Recorder Dashboard - Live Update Mode (Flicker-free, Pi Zero optimized)
# Uses lightweight /proc reads instead of top for CPU monitoring

RECORDER_DIR="$HOME/twitch-recoder/twitch-stream-recorder"
RECORDER_DIR="${TWITCH_RECORDER_DIR:-$RECORDER_DIR}"
LOG_FILE="$RECORDER_DIR/twitch-recorder.log"
RECORDING_DIR="$RECORDER_DIR/recording/recorded"
PROCESSED_DIR="$RECORDER_DIR/recording/processed"
CONFIG_FILE="$RECORDER_DIR/config.json"
[ ! -f "$CONFIG_FILE" ] && CONFIG_FILE="$RECORDER_DIR/config/config.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
WIDTH=65

trap "tput cnorm; clear; exit" INT TERM EXIT
tput civis

format_bytes() {
    local bytes=$1
    if [ $bytes -gt 1073741824 ]; then awk "BEGIN {printf \"%.1fG\", $bytes/1073741824}"
    elif [ $bytes -gt 1048576 ]; then awk "BEGIN {printf \"%.1fM\", $bytes/1048576}"
    else awk "BEGIN {printf \"%.1fK\", $bytes/1024}"; fi
}

wl() {
    local row=$1 text="$2"
    local plain=$(echo -e "$text" | sed 's/\x1b\[[0-9;]*m//g')
    local pad=$((WIDTH - ${#plain})); [ $pad -lt 0 ] && pad=0
    tput cup $row 0; printf "%b%*s" "$text" $pad ""
}

get_channels() {
    [ -f "$CONFIG_FILE" ] && grep -oP '"usernames"\s*:\s*\[\K[^\]]+' "$CONFIG_FILE" 2>/dev/null | tr -d '"' | tr ',' ' '
}

get_recent_logs() {
    [ -f "$LOG_FILE" ] && grep -iE "online|offline|recording|error|started|stopped|failed" "$LOG_FILE" 2>/dev/null | tail -4
}

clear; tput cup 0 0
echo ""; echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${BLUE}           TWITCH RECORDER DASHBOARD (LIVE)${NC}"
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""; echo -e "${BOLD}${YELLOW}📊 STATUS${NC}"; echo ""; echo ""; echo ""
echo -e "${BOLD}${YELLOW}📈 ACTIVE RECORDINGS${NC}"; echo ""; echo ""; echo ""; echo ""
echo -e "${BOLD}${YELLOW}👀 MONITORED CHANNELS${NC}"; echo ""; echo ""
echo -e "${BOLD}${YELLOW}💾 STORAGE${NC}"; echo ""; echo ""; echo ""
echo -e "${BOLD}${YELLOW}⚙️  SYSTEM${NC}"; echo ""; echo ""; echo ""
echo -e "${BOLD}${YELLOW}📜 RECENT EVENTS${NC}"; echo ""; echo ""; echo ""; echo ""
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""; echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"

LOOP=0; CHANNELS=$(get_channels)
PREV_TOTAL=0; PREV_IDLE=0

while true; do
    SECOND=$(date +%s)
    pgrep -f "twitch-recorder.py" > /dev/null && wl 6 "  Recorder: ${GREEN}✓ RUNNING${NC}" || wl 6 "  Recorder: ${RED}✗ NOT RUNNING${NC}"
    
    PIDS=($(pgrep -f "streamlink" 2>/dev/null)); COUNT=${#PIDS[@]}
    RECORDING_CHANNELS=""
    for PID in "${PIDS[@]}"; do
        CH=$(ps -p $PID -o args= 2>/dev/null | grep -oP 'twitch.tv/\K[^ ]+' | head -1)
        [ -n "$CH" ] && RECORDING_CHANNELS="$RECORDING_CHANNELS $CH "
    done
    
    [ $COUNT -gt 0 ] && { ICON=$([[ $((SECOND % 2)) -eq 0 ]] && echo "🔴" || echo "⚫"); wl 7 "  Streams:  ${GREEN}${ICON} ${COUNT} LIVE${NC}"; } || wl 7 "  Streams:  ${YELLOW}○ IDLE${NC}"
    
    for i in 0 1 2; do
        ROW=$((10 + i))
        if [ $i -lt $COUNT ]; then
            PID=${PIDS[$i]}; INFO=$(ps -p $PID -o args= 2>/dev/null)
            CH=$(echo "$INFO" | grep -oP 'twitch.tv/\K[^ ]+' | head -1)
            Q=$(echo "$INFO" | grep -oP '(720p30|720p60|1080p|best)' | head -1); [ -z "$Q" ] && Q="best"
            FILE=$(find "$RECORDING_DIR/$CH" -name "*.mp4" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
            [ -f "$FILE" ] && { SZ=$(stat -c%s "$FILE" 2>/dev/null); wl $ROW "  [$(($i+1))] ${CYAN}${CH}${NC} │ ${Q} │ $(format_bytes $SZ)"; } || wl $ROW "  [$(($i+1))] ${CYAN}${CH}${NC} │ ${Q} │ starting..."
        else wl $ROW "  [$(($i+1))] ─"; fi
    done
    
    if [ -n "$CHANNELS" ]; then
        CHAN_DISPLAY=""
        for ch in $CHANNELS; do
            [[ "$RECORDING_CHANNELS" == *" $ch "* ]] && CHAN_DISPLAY="${CHAN_DISPLAY}${GREEN}●${ch}${NC} " || CHAN_DISPLAY="${CHAN_DISPLAY}○${ch} "
        done
        wl 15 "  ${CHAN_DISPLAY}"
    else wl 15 "  (no channels in config)"; fi
    
    if [ $((LOOP % 10)) -eq 0 ]; then
        REC_SZ=$(du -sh "$RECORDING_DIR" 2>/dev/null | cut -f1)
        PROC_SZ=$(du -sh "$PROCESSED_DIR" 2>/dev/null | cut -f1)
        AVAIL=$(df -h "$RECORDER_DIR" 2>/dev/null | tail -1 | awk '{print $4}')
        wl 18 "  Recorded: ${BOLD}${REC_SZ:-0}${NC} | Processed: ${BOLD}${PROC_SZ:-0}${NC}"
        wl 19 "  Available: ${BOLD}${AVAIL:-N/A}${NC}"
    fi
    
    DISK=$(df -h "$RECORDER_DIR" 2>/dev/null | tail -1 | awk '{print $5}')
    TEMP=$(vcgencmd measure_temp 2>/dev/null | cut -d= -f2 | cut -d\' -f1)
    UP=$(uptime | sed 's/.*up //' | sed 's/,.*//')
    
    # CPU from /proc/stat - inline to avoid subshell issues
    read cpu user nice system idle iowait irq softirq steal guest <<< $(head -1 /proc/stat)
    CURR_TOTAL=$((user + nice + system + idle + iowait + irq + softirq))
    if [ $PREV_TOTAL -gt 0 ]; then
        DT=$((CURR_TOTAL - PREV_TOTAL))
        DI=$((idle - PREV_IDLE))
        [ $DT -gt 0 ] && SYS_CPU=$((100 * (DT - DI) / DT)) || SYS_CPU=0
    else
        SYS_CPU=0
    fi
    PREV_TOTAL=$CURR_TOTAL
    PREV_IDLE=$idle
    
    # Memory from /proc/meminfo
    MEM_INFO=$(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf "%.0f", 100*(t-a)/t}' /proc/meminfo)
    
    # Service CPU & Memory
    SVC_CPU=0; SVC_MEM=0
    REC_PID=$(pgrep -f "twitch-recorder.py" | head -1)
    if [ -n "$REC_PID" ]; then
        read RC RM <<< $(ps -p $REC_PID -o %cpu=,%mem= 2>/dev/null)
        SVC_CPU=$(awk "BEGIN{print $SVC_CPU+${RC:-0}}")
        SVC_MEM=$(awk "BEGIN{print $SVC_MEM+${RM:-0}}")
    fi
    for PID in "${PIDS[@]}"; do
        read PC PM <<< $(ps -p $PID -o %cpu=,%mem= 2>/dev/null)
        SVC_CPU=$(awk "BEGIN{print $SVC_CPU+${PC:-0}}")
        SVC_MEM=$(awk "BEGIN{print $SVC_MEM+${PM:-0}}")
    done
    
    wl 22 "  Disk: ${DISK:-N/A} | Temp: ${TEMP:-N/A}°C | Up: ${UP}"
    wl 23 "  CPU: ${BOLD}${SYS_CPU}%${NC} (svc: ${CYAN}$(printf "%.1f" $SVC_CPU)%${NC}) | Mem: ${BOLD}${MEM_INFO}%${NC} (svc: ${CYAN}$(printf "%.1f" $SVC_MEM)%${NC})"
    
    if [ $((LOOP % 5)) -eq 0 ]; then
        mapfile -t LOGS < <(get_recent_logs)
        for i in 0 1 2 3; do
            ROW=$((26 + i))
            if [ $i -lt ${#LOGS[@]} ]; then
                LOG=$(echo "${LOGS[$i]}" | sed 's/^INFO:root://' | sed 's/^WARNING:root:/⚠ /' | sed 's/^ERROR:root:/✗ /')
                LOG="${LOG:0:58}"
                echo "$LOG" | grep -qi "online\|recording\|started" && { wl $ROW "  ${GREEN}${LOG}${NC}"; continue; }
                echo "$LOG" | grep -qi "offline\|stopped" && { wl $ROW "  ${YELLOW}${LOG}${NC}"; continue; }
                echo "$LOG" | grep -qi "error\|fail" && { wl $ROW "  ${RED}${LOG}${NC}"; continue; }
                wl $ROW "  $LOG"
            else wl $ROW "  ─"; fi
        done
    fi
    
    SPIN=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    wl 32 "Updated: $(date '+%H:%M:%S') ${CYAN}${SPIN[$((SECOND % 10))]}${NC} | Ctrl+C to exit"
    LOOP=$((LOOP + 1)); sleep 1
done
