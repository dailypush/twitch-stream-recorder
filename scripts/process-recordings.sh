#!/bin/bash

# Batch process all recordings using Docker
# Usage: ./process_recordings.sh

# Load shared configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

RECORDINGS_DIR="$TWITCH_RECORDER_RECORDING"
DOCKER_IMAGE="twitch-recorder:latest"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Starting batch FFmpeg processing with Docker${NC}"
echo "Recordings directory: $RECORDINGS_DIR"
echo ""

# Counter
TOTAL=0
PROCESSED=0
FAILED=0

# Process each recorded file
for dir in "$RECORDINGS_DIR/recorded"/*; do
    if [ -d "$dir" ]; then
        username=$(basename "$dir")
        echo -e "${YELLOW}Processing $username...${NC}"
        
        for file in "$dir"/*.mp4; do
            if [ -f "$file" ]; then
                TOTAL=$((TOTAL + 1))
                filename=$(basename "$file")
                output_dir="$RECORDINGS_DIR/processed/$username"
                output_file="$output_dir/${filename}"
                
                # Skip if already processed
                output_size=$(stat -c%s "$output_file" 2>/dev/null || stat -f%z "$output_file" 2>/dev/null || echo 0)
                if [ -f "$output_file" ] && [ -s "$output_file" ] && [ $output_size -gt 1000000 ]; then
                    size_human=$(awk "BEGIN {printf \"%.1fM\", $output_size/1048576}")
                    echo -e "${GREEN}✓${NC} Already processed: $filename (${size_human})"
                    PROCESSED=$((PROCESSED + 1))
                    continue
                fi
                
                echo "  Processing: $filename"
                
                # Run FFmpeg inside Docker
                docker run --rm \
                    -v "$RECORDINGS_DIR:/recordings" \
                    "$DOCKER_IMAGE" \
                    ffmpeg \
                    -err_detect ignore_err \
                    -i "/recordings/recorded/$username/$filename" \
                    -c:v libx264 \
                    -crf 28 \
                    -preset medium \
                    -c:a aac \
                    -b:a 128k \
                    -movflags +faststart \
                    -y \
                    "/recordings/processed/$username/$filename" \
                    2>&1 | grep -E "frame=|Error|error"
                
                if [ $? -eq 0 ]; then
                    # Verify output file size
                    output_size=$(stat -c%s "$output_file" 2>/dev/null || stat -f%z "$output_file" 2>/dev/null || echo 0)
                    if [ -f "$output_file" ] && [ $output_size -gt 1000000 ]; then
                        size_human=$(awk "BEGIN {printf \"%.1fM\", $output_size/1048576}")
                        echo -e "${GREEN}✓ Success${NC}: $filename (${size_human})"
                        PROCESSED=$((PROCESSED + 1))
                    else
                        echo -e "${RED}✗ Failed${NC}: Output file invalid for $filename"
                        FAILED=$((FAILED + 1))
                    fi
                else
                    echo -e "${RED}✗ Failed${NC}: FFmpeg error for $filename"
                    FAILED=$((FAILED + 1))
                fi
            fi
        done
    fi
done

echo ""
echo -e "${YELLOW}Processing complete!${NC}"
echo "Total files: $TOTAL"
echo -e "Processed: ${GREEN}$PROCESSED${NC}"
echo -e "Failed: ${RED}$FAILED${NC}"
