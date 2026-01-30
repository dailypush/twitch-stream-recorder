#!/bin/bash

# Twitch Recorder Dashboard - Watch Mode
# Auto-refreshing dashboard that updates every N seconds
# Usage: dashboard-watch [seconds]
# Example: dashboard-watch 5  (refreshes every 5 seconds)

INTERVAL=${1:-10}  # Default 10 seconds

if ! command -v watch &> /dev/null; then
    echo "Error: 'watch' command not found"
    echo "Install it: sudo apt-get install procps"
    exit 1
fi

echo "Starting dashboard in watch mode (refreshing every ${INTERVAL}s)"
echo "Press Ctrl+C to exit"
echo ""

watch -n "$INTERVAL" "$HOME/twitch-recoder/recorder-dashboard.sh"
