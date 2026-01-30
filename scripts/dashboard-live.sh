#!/bin/bash

# Twitch Recorder Dashboard - Live Update Mode
# Updates values in-place without screen clearing

RECORDER_DIR="$HOME/twitch-recoder/twitch-stream-recorder"
LOG_FILE="$RECORDER_DIR/twitch-recorder.log"
RECORDING_DIR="$RECORDER_DIR/recording/recorded"
PROCESSED_DIR="$RECORDER_DIR/recording/processed"

# ANSI escape codes
CLEAR_LINE="\033[2K"
HIDE_CURSOR="\033[?25l"
SHOW_CURSOR="\033[?25h"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Trap to show cursor on exit
trap "echo -e \"${SHOW_CURSOR}\"; exit" INT TERM EXIT

# Hide cursor for cleaner display
echo -e "${HIDE_CURSOR}"

# Helper function to format bytes
format_bytes() {
    local bytes=$1
    if [ $bytes -gt 1073741824 ]; then
        echo "$(awk "BEGIN {printf \"%.1f\", $bytes/1073741824}")G"
    elif [ $bytes -gt 1048576 ]; then
        echo "$(awk "BEGIN {printf \"%.1f\", $bytes/1048576}")M"
    else
        echo "$(awk "BEGIN {printf \"%.1f\", $bytes/1024}")K"
    fi
}

# Helper function to format time duration
format_time() {
    local seconds=$1
    local days=$((seconds / 86400))
    local hours=$(((seconds % 86400) / 3600))
    local mins=$(((seconds % 3600) / 60))
    
    if [ $days -gt 0 ]; then
        echo "${days}d ${hours}h"
    elif [ $hours -gt 0 ]; then
        echo "${hours}h ${mins}m"
    else
        echo "${mins}m"
    fi
}

# Initial draw
clear
echo ""
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${BLUE}       TWITCH RECORDER DASHBOARD (LIVE)${NC}"
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BOLD}${YELLOW}📊 STATUS${NC}"
echo "  Recorder: [LOADING...]"
echo "  Recording: [CHECKING...]"
echo ""
echo -e "${BOLD}${YELLOW}📈 ACTIVE RECORDING${NC}"
echo "  Channel: ─"
echo "  Quality: ─ | File Size: ─"
echo "  Duration: ─ | Rate: ─"
echo "  Progress: "
echo "  CPU: ─ | Memory: ─"
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
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════${NC}"
echo "Updated: [INITIALIZING...] | Press Ctrl+C to exit"
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════${NC}"

# Function to update a specific line
update_line() {
    local line_num=$1
    local content="$2"
    echo -e "\033[${line_num};1H${CLEAR_LINE}${content}"
}

# Counter for slow updates
LOOP_COUNT=0

# Main update loop
while true; do
    # Animated spinner
    SPINNER_CHARS=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    SECOND=$(date +%s)
    SPINNER_IDX=$(( SECOND % 10 ))
    SPINNER="${SPINNER_CHARS[$SPINNER_IDX]}"
    
    # Line 7: Recorder status
    if pgrep -f "twitch-recorder.py" > /dev/null; then
        update_line 7 "  Recorder: ${GREEN}✓ RUNNING${NC}"
    else
        update_line 7 "  Recorder: ${RED}✗ NOT RUNNING${NC}"
    fi
    
    # Lines 8, 11-15: Recording status
    FILESIZE=0
    DURATION_SEC=0
    if pgrep -f "streamlink" > /dev/null; then
        STREAMLINK_PID=$(pgrep -f "streamlink" | head -1)
        STREAMLINK_INFO=$(ps -p $STREAMLINK_PID -o args=)
        
        CHANNEL=$(echo "$STREAMLINK_INFO" | grep -oP 'twitch.tv/\K[^ ]+' | head -1)
        
        # Extract quality setting from streamlink command
        QUALITY=$(echo "$STREAMLINK_INFO" | grep -oP '(720p30|720p60|1080p60|1080p|best|worst|high|medium|low)' | head -1)
        [ -z "$QUALITY" ] && QUALITY="best"
        
        CPU=$(ps -p $STREAMLINK_PID -o %cpu= | xargs)
        MEM=$(ps -p $STREAMLINK_PID -o %mem= | xargs)
        
        # Find the most recently modified .mp4 file for this channel
        FILE=$(find "$RECORDING_DIR/$CHANNEL" -name "*.mp4" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
        
        # Blinking LIVE indicator
        BLINK_IDX=$(( (SECOND / 2) % 2 ))
        if [ $BLINK_IDX -eq 0 ]; then
            LIVE="🔴"
        else
            LIVE="⚫"
        fi
        
        update_line 8 "  Recording: ${GREEN}${LIVE} LIVE${NC}"
        update_line 11 "  Channel: ${CYAN}${CHANNEL}${NC}"
        
        if [ -n "$FILE" ] && [ -f "$FILE" ]; then
            FILESIZE=$(stat -c%s "$FILE" 2>/dev/null)
            SIZE_FORMATTED=$(format_bytes $FILESIZE)
            
            # Use file access time (when it's being written to) instead of modification time
            FILE_ATIME=$(stat -c%X "$FILE" 2>/dev/null)
            CURRENT_TIME=$(date +%s)
            DURATION_SEC=$((CURRENT_TIME - FILE_ATIME))
            
            # Always show file size and cpu/mem
            update_line 12 "  Quality: ${CYAN}${QUALITY}${NC} | File Size: ${BOLD}${SIZE_FORMATTED}${NC}"
            update_line 15 "  CPU: ${CPU}% | Memory: ${MEM}%"
            
            # Show duration and rate if we have at least 10 seconds of data
            if [ $DURATION_SEC -gt 10 ] && [ $FILESIZE -gt 0 ]; then
                DURATION_MIN=$((DURATION_SEC / 60))
                if [ $DURATION_MIN -gt 60 ]; then
                    DURATION_HR=$((DURATION_MIN / 60))
                    DURATION_MIN_REM=$((DURATION_MIN % 60))
                    DURATION_DISPLAY="${DURATION_HR}h ${DURATION_MIN_REM}m"
                else
                    DURATION_DISPLAY="${DURATION_MIN}m"
                fi
                
                RATE_BPS=$((FILESIZE / DURATION_SEC))
                RATE_MBPM=$(awk "BEGIN {printf \"%.1f\", $RATE_BPS * 60 / 1048576}")
                
                # Progress bar
                SIZE_MB=$((FILESIZE / 1048576))
                BAR_SECTIONS=$((SIZE_MB / 100))
                if [ $BAR_SECTIONS -gt 40 ]; then BAR_SECTIONS=40; fi
                
                PROGRESS_BAR=""
                for ((i=0; i<$BAR_SECTIONS; i++)); do
                    PROGRESS_BAR="${PROGRESS_BAR}█"
                done
                
                update_line 13 "  Duration: ${DURATION_DISPLAY} | Rate: ${RATE_MBPM}MB/min ⬆"
                update_line 14 "  Progress: ${CYAN}${PROGRESS_BAR}${NC}"
            else
                update_line 13 "  Duration: ─ | Rate: ─"
                update_line 14 "  Progress: "
            fi
        else
            update_line 12 "  Quality: ${CYAN}${QUALITY}${NC} | File Size: [scanning...]"
            update_line 13 "  Duration: ─ | Rate: ─"
            update_line 14 "  Progress: "
            update_line 15 "  CPU: ${CPU}% | Memory: ${MEM}%"
        fi
    else
        update_line 8 "  Recording: ${YELLOW}○ IDLE${NC}"
        update_line 11 "  Channel: ─"
        update_line 12 "  Quality: ─ | File Size: ─"
        update_line 13 "  Duration: ─ | Rate: ─"
        update_line 14 "  Progress: "
        update_line 15 "  CPU: ─ | Memory: ─"
    fi
    
    # Line 18: Quick stats (update on first run and every 10 seconds)
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
                            if [ "$FILE_DATE" == "$TODAY" ]; then
                                RECORDINGS_TODAY=$((RECORDINGS_TODAY + 1))
                            fi
                            if [[ "$FILE_DATE" > "$WEEK_AGO" ]] || [[ "$FILE_DATE" == "$WEEK_AGO" ]]; then
                                RECORDINGS_WEEK=$((RECORDINGS_WEEK + 1))
                            fi
                        fi
                    done
                fi
            done
            
            update_line 18 "  Today: ${BOLD}${RECORDINGS_TODAY}${NC} | Week: ${BOLD}${RECORDINGS_WEEK}${NC} | Total: ${BOLD}${TOTAL_RECORDINGS}${NC}"
        fi
    fi
    
    # Line 21-22: Storage (update on first run and every 10 seconds)
    if [ $LOOP_COUNT -eq 0 ] || [ $(( LOOP_COUNT % 10 )) -eq 0 ]; then
        RECORDED_SIZE=$(du -sh "$RECORDING_DIR" 2>/dev/null | cut -f1)
        PROCESSED_SIZE=$(du -sh "$PROCESSED_DIR" 2>/dev/null | cut -f1)
        
        # Calculate total in bytes for accurate sum
        RECORDED_BYTES=$(du -sb "$RECORDING_DIR" 2>/dev/null | cut -f1)
        PROCESSED_BYTES=$(du -sb "$PROCESSED_DIR" 2>/dev/null | cut -f1)
        TOTAL_BYTES=$((RECORDED_BYTES + PROCESSED_BYTES))
        TOTAL_SIZE=$(format_bytes $TOTAL_BYTES)
        
        # Get available disk space
        DISK_INFO=$(df "$RECORDER_DIR" | tail -1)
        AVAIL_BYTES=$(echo "$DISK_INFO" | awk '{print $4}')
        AVAIL_KB=$((AVAIL_BYTES))
        AVAIL_BYTES_ACTUAL=$((AVAIL_KB * 1024))
        AVAIL_FORMATTED=$(format_bytes $AVAIL_BYTES_ACTUAL)
        
        # Calculate time remaining if actively recording
        TIME_LEFT="∞"
        if pgrep -f "streamlink" > /dev/null && [ $DURATION_SEC -gt 10 ] && [ $FILESIZE -gt 0 ]; then
            RATE_BPS=$((FILESIZE / DURATION_SEC))
            if [ $RATE_BPS -gt 0 ]; then
                TIME_LEFT_SEC=$((AVAIL_BYTES_ACTUAL / RATE_BPS))
                TIME_LEFT=$(format_time $TIME_LEFT_SEC)
            fi
        fi
        
        update_line 21 "  Recorded: ${BOLD}${RECORDED_SIZE}${NC} | Processed: ${BOLD}${PROCESSED_SIZE}${NC} | Total: ${BOLD}${TOTAL_SIZE}${NC}"
        update_line 22 "  Available: ${BOLD}${AVAIL_FORMATTED}${NC} | Est. Time Left: ${BOLD}${TIME_LEFT}${NC}"
    fi
    
    # Line 25: System stats
    DISK=$(df -h "$RECORDER_DIR" | tail -1 | awk '{print $5}')
    TEMP=$(vcgencmd measure_temp 2>/dev/null | grep -oP "(?<=temp=)[^']*" || echo "N/A")
    UPTIME=$(uptime | sed 's/.*up //' | sed 's/[,;].*//' | sed 's/  */ /g')
    update_line 25 "  Disk: ${DISK} | Temp: ${TEMP}°C | Uptime: ${UPTIME}"
    
    # Line 28: Timestamp
    update_line 28 "Updated: $(date '+%Y-%m-%d %H:%M:%S') ${CYAN}${SPINNER}${NC} | Press Ctrl+C to exit"
    
    LOOP_COUNT=$((LOOP_COUNT + 1))
    sleep 1
done
