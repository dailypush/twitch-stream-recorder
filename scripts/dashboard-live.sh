#!/bin/bash

# Twitch Recorder Dashboard - Live Update Mode (Flicker-free, Pi Zero optimized)
# Uses lightweight /proc reads instead of top for CPU monitoring

# ═══════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════
RECORDER_DIR="$HOME/twitch-recoder/twitch-stream-recorder"
RECORDER_DIR="${TWITCH_RECORDER_DIR:-$RECORDER_DIR}"
LOG_FILE="$RECORDER_DIR/twitch-recorder.log"
RECORDING_DIR="$RECORDER_DIR/recording/recorded"
PROCESSED_DIR="$RECORDER_DIR/recording/processed"
CONFIG_FILE="$RECORDER_DIR/config.json"
[ ! -f "$CONFIG_FILE" ] && CONFIG_FILE="$RECORDER_DIR/config/config.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

WIDTH=65

trap "tput cnorm; clear; exit" INT TERM EXIT
tput civis

format_bytes() {
    local bytes=$1
    if [ $bytes -gt 1073741824 ]; then
        awk "BEGIN {printf \"%.1fG\", $bytes/1073741824}"
    elif [ $bytes -gt 1048576 ]; then
        awk "BEGIN {printf \"%.1fM\", $bytes/1048576}"
    else
        awk "BEGIN {printf \"%.1fK\", $bytes/1024}"
    fi
}

# Write line at position with padding (flicker-free)
wl() {
    local row=$1
    local text="$2"
    local plain=$(echo -e "$text" | sed 's/\x1b\[[0-9;]*m//g')
    local pad=$((WIDTH - ${#plain}))
    [ $pad -lt 0 ] && pad=0
    tput cup $row 0
    printf "%b%*s" "$text" $pad ""
}

get_channels() {
    if [ -f "$CONFIG_FILE" ]; then
        grep -oP '"usernames"\s*:\s*\[\K[^\]]+' "$CONFIG_FILE" 2>/dev/null | tr -d '"' | tr ',' ' '
    fi
}

get_recent_logs() {
    if [ -f "$LOG_FILE" ]; then
        grep -iE "online|offline|recording|error|started|stopped|failed" "$LOG_FILE" 2>/dev/null | tail -4
    fi
}

# Lightweight CPU reading from /proc/stat (Pi Zero friendly - no top!)
get_cpu_usage() {
    read cpu user nice system idle iowait irq softirq steal guest < /proc/stat
    local total=$((user + nice + system + idle + iowait + irq + softirq))
    local idle_val=$idle
    if [ -n "$PREV_TOTAL" ]; then
        local diff_total=$((total - PREV_TOTAL))
        local diff_idle=$((idle_val - PREV_IDLE))
        [ $diff_total -gt 0 ] && echo $((100 * (diff_total - diff_idle) / diff_total)) || echo 0
    else
        echo 0
    fi
    PREV_TOTAL=$total
    PREV_IDLE=$idle_val
    fi
}

# Function to update a specific line using tput (more reliable)
update_line() {
    local line_num=$1
    local content="$2"
    tput cup $((line_num - 1)) 0  # tput is 0-indexed
    tput el                        # clear to end of line
    printf "%b" "$content"
}

# Initial draw
clear
tput cup 0 0
echo ""
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${BLUE}           TWITCH RECORDER DASHBOARD (LIVE)${NC}"
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BOLD}${YELLOW}📊 STATUS${NC}"
echo "  Recorder: [LOADING...]"
echo "  Streams:  [CHECKING...]"
echo ""
echo -e "${BOLD}${YELLOW}📈 ACTIVE RECORDINGS${NC}"
echo "  [1] ─"
echo "  [2] ─"
echo "  [3] ─"
echo ""
echo -e "${BOLD}${YELLOW}👀 MONITORED CHANNELS${NC}"
echo "  ─"
echo ""
echo -e "${BOLD}${YELLOW}📊 QUICK STATS${NC}"
echo "  Today: ─ | Week: ─ | Total: ─"
echo ""
echo -e "${BOLD}${YELLOW}💾 STORAGE${NC}"
echo "  Recorded: ─ | Processed: ─ | Total: ─"
echo "  Available: ─ | Est. Time Left: ─"
echo ""
echo -e "${BOLD}${YELLOW}⚙️  SYSTEM${NC}"
echo "  Disk: ─ | Temp: ─ | Uptime: ─"
echo ""
echo -e "${BOLD}${YELLOW}📜 RECENT LOGS${NC}"
echo "  ─"
echo "  ─"
echo "  ─"
echo "  ─"
echo "  ─"
echo ""
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo "Updated: [INITIALIZING...] | Press Ctrl+C to exit"
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"

# Function to get monitored channels from config or log
get_monitored_channels() {
    # Try to get from config.json
    if [ -f "$CONFIG_FILE" ]; then
        CHANNELS=$(grep -oP '"username"\s*:\s*"\K[^"]+' "$CONFIG_FILE" 2>/dev/null | tr '\n' ' ')
        if [ -n "$CHANNELS" ]; then
            echo "$CHANNELS"
            return
        fi
    fi
    
    # Fallback: parse from log file
    if [ -f "$LOG_FILE" ]; then
        CHANNELS=$(grep -oP 'Checking user \K\w+' "$LOG_FILE" 2>/dev/null | sort -u | tr '\n' ' ')
        echo "$CHANNELS"
    fi
}

# Counter for slow updates
LOOP_COUNT=0

# Layout line numbers - MUST match initial draw exactly!
# Line 1: blank, 2-4: header, 5: blank, 6: STATUS header
LINE_RECORDER=7
LINE_STREAMS=8
# Line 9: blank, 10: ACTIVE RECORDINGS header
LINE_REC_START=11
# Line 14: blank, 15: MONITORED CHANNELS header
LINE_CHANNELS=16
# Line 17: blank, 18: QUICK STATS header
LINE_STATS=19
# Line 20: blank, 21: STORAGE header
LINE_STORAGE1=22
LINE_STORAGE2=23
# Line 24: blank, 25: SYSTEM header
LINE_SYSTEM=26
# Line 27: blank, 28: RECENT LOGS header
LINE_LOGS_START=29
# Line 34: blank, 35-37: footer
LINE_TIMESTAMP=36

# Main update loop
while true; do
    # Animated spinner
    SPINNER_CHARS=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    SECOND=$(date +%s)
    SPINNER_IDX=$(( SECOND % 10 ))
    SPINNER="${SPINNER_CHARS[$SPINNER_IDX]}"
    
    # Blinking indicator
    BLINK_IDX=$(( (SECOND / 2) % 2 ))
    
    # Line 7: Recorder status
    if pgrep -f "twitch-recorder.py" > /dev/null; then
        update_line $LINE_RECORDER "  Recorder: ${GREEN}✓ RUNNING${NC}"
    else
        update_line $LINE_RECORDER "  Recorder: ${RED}✗ NOT RUNNING${NC}"
    fi
    
    # Get all active streamlink processes
    STREAMLINK_PIDS=($(pgrep -f "streamlink" 2>/dev/null))
    STREAM_COUNT=${#STREAMLINK_PIDS[@]}
    
    # Track total rate for time estimate
    TOTAL_RATE_BPS=0
    
    if [ $STREAM_COUNT -gt 0 ]; then
        if [ $BLINK_IDX -eq 0 ]; then
            LIVE_ICON="🔴"
        else
            LIVE_ICON="⚫"
        fi
        update_line $LINE_STREAMS "  Streams:  ${GREEN}${LIVE_ICON} ${STREAM_COUNT} LIVE${NC}"
        
        # Show up to 3 active recordings
        for i in 0 1 2; do
            LINE_NUM=$((LINE_REC_START + i))
            
            if [ $i -lt $STREAM_COUNT ]; then
                PID=${STREAMLINK_PIDS[$i]}
                INFO=$(ps -p $PID -o args= 2>/dev/null)
                
                CHANNEL=$(echo "$INFO" | grep -oP 'twitch.tv/\K[^ ]+' | head -1)
                QUALITY=$(echo "$INFO" | grep -oP '(720p30|720p60|1080p60|1080p|best|worst|high|medium|low)' | head -1)
                [ -z "$QUALITY" ] && QUALITY="best"
                
                CPU=$(ps -p $PID -o %cpu= 2>/dev/null | xargs)
                
                # Find recording file
                FILE=$(find "$RECORDING_DIR/$CHANNEL" -name "*.mp4" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
                
                if [ -n "$FILE" ] && [ -f "$FILE" ]; then
                    FILESIZE=$(stat -c%s "$FILE" 2>/dev/null || echo 0)
                    SIZE_FMT=$(format_bytes $FILESIZE)
                    
                    # Get duration from file creation time
                    FILE_CTIME=$(stat -c%W "$FILE" 2>/dev/null)
                    [ "$FILE_CTIME" = "0" ] && FILE_CTIME=$(stat -c%Y "$FILE" 2>/dev/null)
                    DURATION_SEC=$((SECOND - FILE_CTIME))
                    
                    if [ $DURATION_SEC -gt 10 ] && [ $FILESIZE -gt 0 ]; then
                        RATE_BPS=$((FILESIZE / DURATION_SEC))
                        TOTAL_RATE_BPS=$((TOTAL_RATE_BPS + RATE_BPS))
                        RATE_MBPM=$(awk "BEGIN {printf \"%.1f\", $RATE_BPS * 60 / 1048576}")
                        DUR_FMT=$(format_time $DURATION_SEC)
                        update_line $LINE_NUM "  [$(($i+1))] ${CYAN}${CHANNEL}${NC} │ ${QUALITY} │ ${SIZE_FMT} │ ${DUR_FMT} │ ${RATE_MBPM}MB/m │ CPU:${CPU}%"
                    else
                        update_line $LINE_NUM "  [$(($i+1))] ${CYAN}${CHANNEL}${NC} │ ${QUALITY} │ ${SIZE_FMT} │ starting..."
                    fi
                else
                    update_line $LINE_NUM "  [$(($i+1))] ${CYAN}${CHANNEL}${NC} │ ${QUALITY} │ initializing..."
                fi
            else
                update_line $LINE_NUM "  [$(($i+1))] ─"
            fi
        done
    else
        update_line $LINE_STREAMS "  Streams:  ${YELLOW}○ IDLE${NC} (no active recordings)"
        update_line $LINE_REC_START "  [1] ─"
        update_line $((LINE_REC_START + 1)) "  [2] ─"
        update_line $((LINE_REC_START + 2)) "  [3] ─"
    fi
    
    # Monitored channels (update every 30 seconds)
    if [ $LOOP_COUNT -eq 0 ] || [ $(( LOOP_COUNT % 30 )) -eq 0 ]; then
        MONITORED=$(get_monitored_channels)
        if [ -n "$MONITORED" ]; then
            # Color active channels green
            DISPLAY_CHANNELS=""
            for ch in $MONITORED; do
                if echo "${STREAMLINK_PIDS[@]}" | xargs -I{} ps -p {} -o args= 2>/dev/null | grep -qi "$ch"; then
                    DISPLAY_CHANNELS="${DISPLAY_CHANNELS}${GREEN}●${ch}${NC} "
                else
                    DISPLAY_CHANNELS="${DISPLAY_CHANNELS}○${ch} "
                fi
            done
            update_line $LINE_CHANNELS "  ${DISPLAY_CHANNELS}"
        else
            update_line $LINE_CHANNELS "  (no channels configured)"
        fi
    fi
    
    # Quick stats (update every 10 seconds)
    if [ $LOOP_COUNT -eq 0 ] || [ $(( LOOP_COUNT % 10 )) -eq 0 ]; then
        if [ -d "$RECORDING_DIR" ]; then
            TODAY=$(date +%Y-%m-%d)
            WEEK_AGO=$(date -d '7 days ago' +%Y-%m-%d 2>/dev/null || date -v-7d +%Y-%m-%d 2>/dev/null)
            
            TOTAL_RECORDINGS=0
            RECORDINGS_TODAY=0
            RECORDINGS_WEEK=0
            
            for channel_dir in "$RECORDING_DIR"/*; do
                if [ -d "$channel_dir" ]; then
                    for file in "$channel_dir"/*.mp4; do
                        if [ -f "$file" ]; then
                            TOTAL_RECORDINGS=$((TOTAL_RECORDINGS + 1))
                            FILE_DATE=$(stat -c%y "$file" 2>/dev/null | cut -d' ' -f1)
                            [ "$FILE_DATE" == "$TODAY" ] && RECORDINGS_TODAY=$((RECORDINGS_TODAY + 1))
                            [[ "$FILE_DATE" > "$WEEK_AGO" || "$FILE_DATE" == "$WEEK_AGO" ]] && RECORDINGS_WEEK=$((RECORDINGS_WEEK + 1))
                        fi
                    done
                fi
            done
            
            update_line $LINE_STATS "  Today: ${BOLD}${RECORDINGS_TODAY}${NC} | Week: ${BOLD}${RECORDINGS_WEEK}${NC} | Total: ${BOLD}${TOTAL_RECORDINGS}${NC}"
        fi
    fi
    
    # Storage (update every 10 seconds)
    if [ $LOOP_COUNT -eq 0 ] || [ $(( LOOP_COUNT % 10 )) -eq 0 ]; then
        RECORDED_SIZE=$(du -sh "$RECORDING_DIR" 2>/dev/null | cut -f1 || echo "0")
        PROCESSED_SIZE=$(du -sh "$PROCESSED_DIR" 2>/dev/null | cut -f1 || echo "0")
        
        RECORDED_BYTES=$(du -sb "$RECORDING_DIR" 2>/dev/null | cut -f1 || echo 0)
        PROCESSED_BYTES=$(du -sb "$PROCESSED_DIR" 2>/dev/null | cut -f1 || echo 0)
        TOTAL_BYTES=$((RECORDED_BYTES + PROCESSED_BYTES))
        TOTAL_SIZE=$(format_bytes $TOTAL_BYTES)
        
        # Available disk space
        AVAIL_KB=$(df "$RECORDER_DIR" 2>/dev/null | tail -1 | awk '{print $4}')
        AVAIL_BYTES=$((AVAIL_KB * 1024))
        AVAIL_FMT=$(format_bytes $AVAIL_BYTES)
        
        # Time remaining estimate
        TIME_LEFT="∞"
        if [ $TOTAL_RATE_BPS -gt 0 ]; then
            TIME_LEFT_SEC=$((AVAIL_BYTES / TOTAL_RATE_BPS))
            TIME_LEFT=$(format_time $TIME_LEFT_SEC)
        fi
        
        update_line $LINE_STORAGE1 "  Recorded: ${BOLD}${RECORDED_SIZE}${NC} | Processed: ${BOLD}${PROCESSED_SIZE}${NC} | Total: ${BOLD}${TOTAL_SIZE}${NC}"
        update_line $LINE_STORAGE2 "  Available: ${BOLD}${AVAIL_FMT}${NC} | Est. Time Left: ${BOLD}${TIME_LEFT}${NC}"
    fi
    
    # System stats
    DISK=$(df -h "$RECORDER_DIR" 2>/dev/null | tail -1 | awk '{print $5}' || echo "N/A")
    TEMP=$(vcgencmd measure_temp 2>/dev/null | grep -oP '(?<=temp=)[^'"'"']*' || echo "N/A")
    UPTIME=$(uptime | sed 's/.*up //' | sed 's/[,;].*//' | sed 's/  */ /g')
    update_line $LINE_SYSTEM "  Disk: ${DISK} | Temp: ${TEMP}°C | Uptime: ${UPTIME}"
    
    # Recent logs (last 5 lines, update every 5 seconds)
    if [ $LOOP_COUNT -eq 0 ] || [ $(( LOOP_COUNT % 5 )) -eq 0 ]; then
        if [ -f "$LOG_FILE" ]; then
            # Get last 5 meaningful log lines (skip blank, truncate long lines)
            mapfile -t LOG_LINES < <(grep -v '^$' "$LOG_FILE" 2>/dev/null | tail -5)
            
            for i in 0 1 2 3 4; do
                LINE_NUM=$((LINE_LOGS_START + i))
                if [ $i -lt ${#LOG_LINES[@]} ]; then
                    # Truncate to ~58 chars, colorize
                    LOG_TEXT="${LOG_LINES[$i]:0:58}"
                    # Color based on content
                    if echo "$LOG_TEXT" | grep -qi "error\|fail"; then
                        update_line $LINE_NUM "  ${RED}${LOG_TEXT}${NC}"
                    elif echo "$LOG_TEXT" | grep -qi "online\|recording\|started"; then
                        update_line $LINE_NUM "  ${GREEN}${LOG_TEXT}${NC}"
                    elif echo "$LOG_TEXT" | grep -qi "offline\|stopped"; then
                        update_line $LINE_NUM "  ${YELLOW}${LOG_TEXT}${NC}"
                    else
                        update_line $LINE_NUM "  ${LOG_TEXT}"
                    fi
                else
                    update_line $LINE_NUM "  ─"
                fi
            done
        fi
    fi
    
    # Timestamp
    update_line $LINE_TIMESTAMP "Updated: $(date '+%Y-%m-%d %H:%M:%S') ${CYAN}${SPINNER}${NC} | Press Ctrl+C to exit"
    
    LOOP_COUNT=$((LOOP_COUNT + 1))
    sleep 1
done
