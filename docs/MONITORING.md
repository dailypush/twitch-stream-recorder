# Twitch Recorder Dashboard - Quick Reference

## Quick Start

SSH into the Raspberry Pi and run the dashboard:

```bash
ssh pi@raspberrypi.local
dashboard
```

## What the Dashboard Shows

### 1. **RECORDER PROCESS STATUS**
- Check if the main Python process is running
- Shows PID and start time
- ✓ Green = Running | ✗ Red = Not running

### 2. **ACTIVE RECORDING**
- Shows which channel is currently being recorded
- File name and current size
- CPU and Memory usage of streamlink process
- ○ Yellow = Idle (waiting for a stream) | ✓ Green = Recording

### 3. **LATEST RECORDINGS BY CHANNEL**
- Most recent file recorded for each channel
- File size and last modified time
- Useful for checking if new recordings are being created

### 4. **STORAGE USAGE**
- Breakdown by channel
- Total storage consumed
- Use this to monitor disk space

### 5. **RECENT LOG ENTRIES**
- Last 15 lines from twitch-recorder.log
- Shows which channels are being monitored
- Indicates online/offline status and any errors

### 6. **SYSTEM STATUS**
- Disk usage percentage
- System uptime (how long since last reboot)
- CPU temperature

---

## Manual Commands

If you prefer running individual checks instead of the full dashboard:

### Check if recorder is running
```bash
ps aux | grep twitch-recorder.py
```

### Check current active recording
```bash
ps aux | grep streamlink
```

### View last log entries
```bash
tail -30 ~/twitch-recoder/twitch-stream-recorder/twitch-recorder.log
```

### Check storage by channel
```bash
du -sh ~/twitch-recoder/twitch-stream-recorder/recording/recorded/*
```

### Find recent recordings
```bash
find ~/twitch-recoder/twitch-stream-recorder/recording -name "*.mp4" -mmin -120
```

---

## Troubleshooting

### Script not found
Make sure you're in the right directory or use the full path:
```bash
/home/pi/twitch-recoder/recorder-dashboard.sh
```

### Colors not showing properly
The script uses ANSI color codes. If colors don't display, try:
```bash
bash /home/pi/twitch-recoder/recorder-dashboard.sh
```

### Permission denied
Make sure the script is executable:
```bash
chmod +x /home/pi/twitch-recoder/recorder-dashboard.sh
```

---

## Setting up the Alias (Optional)

If you haven't set up the alias yet:
```bash
echo "alias dashboard='/home/pi/twitch-recoder/recorder-dashboard.sh'" >> ~/.bashrc
source ~/.bashrc
```

Then you can simply run:
```bash
dashboard
```

---

## Key Metrics to Monitor

| Metric | Healthy Range | Warning | Critical |
|--------|---------------|---------|----------|
| CPU Usage | < 50% | 50-75% | > 75% |
| Memory Usage | < 20% | 20-40% | > 40% |
| Disk Usage | < 80% | 80-95% | > 95% |
| CPU Temp | < 50°C | 50-70°C | > 70°C |

---

## Recent Status (Last Run)

**pyka** - Currently recording (739M file)
- CPU: 38.9% | Memory: 9.4%
- Storage: 13G total

**sheensayerdj** - Latest: 2026-01-26 (14G total)

**System**: 7 days uptime, 29% disk used, 44.4°C CPU temp
