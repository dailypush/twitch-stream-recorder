# Twitch Stream Recorder - Configuration Guide

## Recording and background processing

Set these options in `config/config.json`:

| Option | Default | Behavior |
|--------|---------|----------|
| `processing_threads` | `1` | FFmpeg decoder/encoder thread limit for idle compression; minimum 1. |
| `recording_stall_timeout_seconds` | `300` | Stop a recording with no file growth for this long, including a missing output file; minimum 30 seconds. The next online check can start a fresh recording. Allow enough time for ad breaks and network interruptions. |
| `retention_check_interval_seconds` | `3600` | Check retention at startup and periodically while running; minimum 60 seconds. Checks defer while background processing is active. |
| `prune_after_days` | `30` | Delete recordings older than this many whole days; zero or negative disables retention. Active channels' raw recordings and files awaiting upload are protected. |
| `disable_ffmpeg` | `false` | Skip remuxing and compression, while still moving completed recordings and uploading them when enabled. Raw stream container formats are preserved. |

Online checks continue under high CPU load. `cpu_threshold` and `memory_threshold`
still govern new recordings; CPU consumed by background FFmpeg does not block a
new recording, because background FFmpeg yields to it. `check_cpu_threshold` is
no longer used. Compression runs at reduced process priority on POSIX systems.
Background FFmpeg stops on recording activity or shutdown and restarts its work
from the beginning on a later idle cycle. Interruptions do not consume the remux
failure retry budget.

FFmpeg processing requires `ffprobe` alongside the configured `ffmpeg` executable
(or both on `PATH` when using the default names). Remux and compression outputs
are written to temporary files, checked for readable duration and truncation,
and atomically published. These checks do not perform a full frame-by-frame decode.

When network uploads are enabled, `.upload-pending` sidecars persist until a
complete copy is published. Failed copies retry during later idle cycles,
including after a restart. Pending files are not compressed or pruned, so an
unavailable destination can increase local disk usage. Network copies use
temporary files in the destination directory and an atomic rename; compression
of the local copy afterward does not replace the already uploaded version.

Run `scripts/process-recordings.sh` with the recorder stopped so the batch tool
does not process files still being recorded. The batch tool validates output
with FFprobe, publishes successful outputs atomically, and exits nonzero when
any file fails.

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
