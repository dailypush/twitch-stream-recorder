# Twitch Stream Recorder - Configuration Guide

## Environment Variables

All scripts now use a shared configuration system via `scripts/config.sh`. This eliminates hardcoded paths and makes the project portable.

### Base Configuration

Set the base directory to customize the installation location:

```bash
export TWITCH_RECORDER_BASE="/path/to/your/twitch-stream-recorder"
```

If not set, the scripts will auto-detect the base directory relative to the scripts folder.

### Available Environment Variables

All variables are automatically set by `scripts/config.sh`:

| Variable | Default | Description |
|----------|---------|-------------|
| `TWITCH_RECORDER_BASE` | Auto-detected | Base installation directory |
| `TWITCH_RECORDER_DIR` | Same as BASE | Main recorder directory |
| `TWITCH_RECORDER_SCRIPTS` | `$BASE/scripts` | Scripts directory |
| `TWITCH_RECORDER_LOGS` | `$BASE/logs` | Log files directory |
| `TWITCH_RECORDER_RECORDING` | `$BASE/recording` | Recording base directory |
| `TWITCH_RECORDER_RECORDED` | `$BASE/recording/recorded` | Raw recordings |
| `TWITCH_RECORDER_PROCESSED` | `$BASE/recording/processed` | Processed recordings |
| `TWITCH_RECORDER_BACKUP` | `$BASE/recording/backup` | Backup directory |
| `TWITCH_RECORDER_CONFIG` | `$BASE/config.json` | Main config file |
| `TWITCH_RECORDER_MAIN_LOG` | `$BASE/twitch-recorder.log` | Main log file |
| `TWITCH_RECORDER_VALIDATION_LOG` | `$LOGS/validation.log` | Validation log |
| `TWITCH_RECORDER_REPAIR_LOG` | `$LOGS/repair.log` | Repair log |
| `TWITCH_RECORDER_CLEANUP_LOG` | `$LOGS/cleanup.log` | Cleanup log |

### Custom Installation Example

For a custom installation path, set the environment variable before running scripts:

```bash
# In ~/.bashrc or ~/.profile
export TWITCH_RECORDER_BASE="/mnt/storage/twitch-recorder"

# Then run scripts normally
./scripts/dashboard-live.sh
```

### Multi-Instance Setup

To run multiple instances (e.g., different streamers):

```bash
# Instance 1
export TWITCH_RECORDER_BASE="/home/pi/twitch-gaming"
./scripts/dashboard-live.sh

# Instance 2
export TWITCH_RECORDER_BASE="/home/pi/twitch-music"
./scripts/dashboard-live.sh
```

### Systemd Service Configuration

Update your systemd service to use environment variables:

```ini
[Service]
Environment="TWITCH_RECORDER_BASE=/home/pi/twitch-recoder/twitch-stream-recorder"
WorkingDirectory=/home/pi/twitch-recoder/twitch-stream-recorder
ExecStart=/usr/bin/python3 twitch-recorder.py
```

## Migration from Hardcoded Paths

All scripts have been updated to use the shared configuration. No action needed for standard installations. If you have custom paths, set `TWITCH_RECORDER_BASE` appropriately.
