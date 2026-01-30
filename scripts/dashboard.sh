#!/bin/bash

# Twitch Recorder Dashboard - Enhanced Version with Animation
# Run: ~/twitch-recoder/recorder-dashboard.sh

RECORDER_DIR="$HOME/twitch-recoder/twitch-stream-recorder"
LOG_FILE="$RECORDER_DIR/twitch-recorder.log"
RECORDING_DIR="$RECORDER_DIR/recording/recorded"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
BLINK='\033[5m'
NC='\033[0m'

# Animated spinner
SPINNER_CHARS=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
SECOND=$(date +%s)
SPINNER_IDX=$(( SECOND % 10 ))
SPINNER="${SPINNER_CHARS[$SPINNER_IDX]}"

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

echo ""
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${BLUE}       TWITCH RECORDER DASHBOARD ${CYAN}${SPINNER}${NC}"
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════${NC}"
echo ""

# 1. PROCESS STATUS
echo -e "${BOLD}${YELLOW}1. RECORDER PROCESS STATUS${NC}"
echo -e "${BOLD}───────────────────────────────────────────────────────${NC}"
if pgrep -f "twitch-recorder.py" > /dev/null; then
    PID=$(pgrep -f "twitch-recorder.py")
    START_TIME=$(ps -p $PID -o lstart=)
    echo -e "${GREEN}✓ RUNNING${NC}"
    echo "  PID: $PID"
    echo "  Started: $START_TIME"
else
    echo -e "${RED}✗ NOT RUNNING${NC}"
fi
echo ""

# 2. ACTIVE RECORDING WITH REAL-TIME STATS
echo -e "${BOLD}${YELLOW}2. ACTIVE RECORDING${NC}"
echo -e "${BOLD}───────────────────────────────────────────────────────${NC}"
if pgrep -f "streamlink" > /dev/null; then
    STREAMLINK_PID=$(pgrep -f "streamlink")
    STREAMLINK_INFO=$(ps -p $STREAMLINK_PID -o cmd=)
    
    CHANNEL=$(echo "$STREAMLINK_INFO" | grep -oP 'twitch.tv/\K[^ ]+' | head -1)
    FILE=$(echo "$STREAMLINK_INFO" | grep -oP '(?<=-o ).*' | head -1)
    
    CPU=$(ps -p $STREAMLINK_PID -o %cpu= | xargs)
    MEM=$(ps -p $STREAMLINK_PID -o %mem= | xargs)
    
    # Animated LIVE indicator
    BLINK_CHARS=("🔴" "⚫")
    BLINK_IDX=$(( (SECOND / 2) % 2 ))
    LIVE_INDICATOR="${BLINK_CHARS[$BLINK_IDX]}"
    
    echo -e "${GREEN}${LIVE_INDICATOR} RECORDING IN PROGRESS${NC}"
    echo "  Channel: $CHANNEL"
    echo "  File: $(basename "$FILE")"
    
    if [ -f "$FILE" ]; then
        # Get file size
        FILESIZE=$(stat -c%s "$FILE" 2>/dev/null)
        SIZE_FORMATTED=$(format_bytes $FILESIZE)
        
        # Calculate recording duration and rate
        FILE_MTIME=$(stat -c%Y "$FILE" 2>/dev/null)
        CURRENT_TIME=$(date +%s)
        DURATION_SEC=$((CURRENT_TIME - FILE_MTIME))
        
        if [ $DURATION_SEC -gt 0 ]; then
            DURATION_MIN=$((DURATION_SEC / 60))
            DURATION_DISPLAY="${DURATION_MIN}m"
            if [ $DURATION_MIN -gt 60 ]; then
                DURATION_HR=$((DURATION_MIN / 60))
                DURATION_MIN_REM=$((DURATION_MIN % 60))
                DURATION_DISPLAY="${DURATION_HR}h ${DURATION_MIN_REM}m"
            fi
            
            # Calculate rate (bytes per second)
            RATE_BPS=$((FILESIZE / DURATION_SEC))
            RATE_MBPM=$(awk "BEGIN {printf \"%.1f\", $RATE_BPS * 60 / 1048576}")
            
            # Progress bar based on file size
            SIZE_MB=$((FILESIZE / 1048576))
            BAR_SECTIONS=$((SIZE_MB / 100))
            if [ $BAR_SECTIONS -gt 50 ]; then BAR_SECTIONS=50; fi
            
            PROGRESS_BAR=""
            for ((i=0; i<$BAR_SECTIONS; i++)); do
                PROGRESS_BAR="${PROGRESS_BAR}█"
            done
            if [ ! -z "$PROGRESS_BAR" ]; then
                echo -e "  ${CYAN}${PROGRESS_BAR}${NC} ${SIZE_FORMATTED}"
            fi
            
            echo "  Duration: $DURATION_DISPLAY | Rate: ${RATE_MBPM}MB/min ⬆"
        else
            echo "  Size: $SIZE_FORMATTED"
        fi
    fi
    echo "  Resources: CPU ${CPU}% | Memory ${MEM}%"
else
    echo -e "${YELLOW}○ IDLE (No active recording)${NC}"
fi
echo ""

# 3. QUICK STATS
echo -e "${BOLD}${YELLOW}3. QUICK STATS${NC}"
echo -e "${BOLD}───────────────────────────────────────────────────────${NC}"

if [ -d "$RECORDING_DIR" ]; then
    # Get today's date
    TODAY=$(date +%Y-%m-%d)
    WEEK_AGO=$(date -d '7 days ago' +%Y-%m-%d 2>/dev/null || date -v-7d +%Y-%m-%d 2>/dev/null)
    
    # Count recordings
    TOTAL_RECORDINGS=0
    RECORDINGS_TODAY=0
    RECORDINGS_WEEK=0
    TOTAL_SIZE=0
    LARGEST_SIZE=0
    SMALLEST_SIZE=999999999999
    
    for channel_dir in "$RECORDING_DIR"/*; do
        if [ -d "$channel_dir" ]; then
            for file in "$channel_dir"/*.mp4; do
                if [ -f "$file" ]; then
                    TOTAL_RECORDINGS=$((TOTAL_RECORDINGS + 1))
                    FILESIZE=$(stat -c%s "$file" 2>/dev/null)
                    TOTAL_SIZE=$((TOTAL_SIZE + FILESIZE))
                    
                    # Check if today
                    FILE_DATE=$(stat -c%y "$file" 2>/dev/null | cut -d' ' -f1)
                    if [ "$FILE_DATE" == "$TODAY" ]; then
                        RECORDINGS_TODAY=$((RECORDINGS_TODAY + 1))
                    fi
                    
                    # Check if this week
                    if [[ "$FILE_DATE" > "$WEEK_AGO" ]] || [[ "$FILE_DATE" == "$WEEK_AGO" ]]; then
                        RECORDINGS_WEEK=$((RECORDINGS_WEEK + 1))
                    fi
                    
                    # Track largest
                    if [ $FILESIZE -gt $LARGEST_SIZE ]; then
                        LARGEST_SIZE=$FILESIZE
                    fi
                    
                    # Track smallest (but bigger than 10MB to avoid partial files)
                    if [ $FILESIZE -lt $SMALLEST_SIZE ] && [ $FILESIZE -gt 10485760 ]; then
                        SMALLEST_SIZE=$FILESIZE
                    fi
                fi
            done
        fi
    done
    
    echo "  Total Recordings: $TOTAL_RECORDINGS files"
    echo "  Recorded Today: $RECORDINGS_TODAY | This Week: $RECORDINGS_WEEK"
    
    if [ $TOTAL_RECORDINGS -gt 0 ]; then
        AVG_SIZE=$((TOTAL_SIZE / TOTAL_RECORDINGS))
        echo "  Average Size: $(format_bytes $AVG_SIZE)"
        echo "  Largest: $(format_bytes $LARGEST_SIZE)"
        echo "  Smallest: $(format_bytes $SMALLEST_SIZE)"
    fi
else
    echo "  Recording directory not found"
fi
echo ""

# 4. LATEST RECORDINGS BY CHANNEL
echo -e "${BOLD}${YELLOW}4. LATEST RECORDINGS BY CHANNEL${NC}"
echo -e "${BOLD}───────────────────────────────────────────────────────${NC}"
if [ -d "$RECORDING_DIR" ]; then
    for channel in $(ls "$RECORDING_DIR" 2>/dev/null); do
        if [ -d "$RECORDING_DIR/$channel" ]; then
            LATEST=$(ls -t "$RECORDING_DIR/$channel"/*.mp4 2>/dev/null | head -1)
            if [ ! -z "$LATEST" ]; then
                SIZE=$(du -h "$LATEST" | cut -f1)
                MTIME=$(stat -c%y "$LATEST" 2>/dev/null | cut -d' ' -f1-2)
                echo -e "  ${BLUE}$channel${NC}"
                echo "    Latest: $(basename "$LATEST")"
                echo "    Size: $SIZE | Modified: $MTIME"
            fi
        fi
    done
else
    echo "  Recording directory not found"
fi
echo ""

# 5. STORAGE USAGE
echo -e "${BOLD}${YELLOW}5. STORAGE USAGE${NC}"
echo -e "${BOLD}───────────────────────────────────────────────────────${NC}"
if [ -d "$RECORDING_DIR" ]; then
    echo "  By Channel:"
    du -sh "$RECORDING_DIR"/* 2>/dev/null | sed 's/^/    /'
    echo ""
    TOTAL=$(du -sh "$RECORDING_DIR" 2>/dev/null | cut -f1)
    echo "  Total: $TOTAL"
else
    echo "  Recording directory not found"
fi
echo ""

# 6. RECENT LOG ENTRIES
echo -e "${BOLD}${YELLOW}6. RECENT LOG ENTRIES${NC}"
echo -e "${BOLD}───────────────────────────────────────────────────────${NC}"
if [ -f "$LOG_FILE" ]; then
    tail -10 "$LOG_FILE" | sed 's/^/  /'
else
    echo "  Log file not found"
fi
echo ""

# 7. SYSTEM STATUS
echo -e "${BOLD}${YELLOW}7. SYSTEM STATUS${NC}"
echo -e "${BOLD}───────────────────────────────────────────────────────${NC}"
DISK=$(df -h "$RECORDER_DIR" | tail -1 | awk '{print $5}')
UPTIME=$(uptime | sed 's/.*up //' | sed 's/[,;].*//')
TEMP=$(vcgencmd measure_temp 2>/dev/null | grep -oP "(?<=temp=)[^']*" || echo "N/A")

echo "  Disk Usage: $DISK"
echo "  System Uptime: $UPTIME"
if [ "$TEMP" != "N/A" ]; then
    echo "  CPU Temp: ${TEMP}°C"
fi
echo ""

echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "Updated: $(date '+%Y-%m-%d %H:%M:%S') ${CYAN}${SPINNER}${NC}"
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════${NC}"
echo ""
