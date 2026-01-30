# Twitch Recorder

Twitch Recorder is a Python script for automatically recording live streams of specified Twitch users, processing the video files, and saving them to your computer. This script is an improved version of [junian's twitch-recorder](https://gist.github.com/junian/b41dd8e544bf0e3980c971b0d015f5f6), migrated to [**helix**](https://dev.twitch.tv/docs/api), the new Twitch API, and utilizes OAuth2.

## Project Structure

```
twitch-stream-recorder/
├── twitch-recorder.py          # Main application
├── requirements.txt
├── config/
│   ├── config.json             # Your configuration (gitignored)
│   └── config.example.json     # Example configuration template
├── scripts/
│   ├── dashboard-live.sh       # Real-time monitoring dashboard
│   ├── dashboard.sh            # Standard monitoring dashboard
│   ├── dashboard-watch.sh      # Auto-refreshing dashboard
│   ├── validate-recordings.sh  # MP4 integrity checker
│   └── process-recordings.sh   # Batch processing script
├── systemd/
│   ├── twitch-recorder.service # Systemd service file
│   └── install.sh              # Service installation script
├── docker/
│   ├── dockerfile
│   └── compose-dev.yaml
└── docs/
    ├── MONITORING.md           # Dashboard documentation
    ├── SYSTEMD_SETUP.md        # Service setup guide
    └── VALIDATION_AND_WATCH.md # Validation tools guide
```

## Requirements

1. [Python 3.8](https://www.python.org/downloads/release/python-380/) or higher
2. [Streamlink](https://streamlink.github.io/)
3. [FFmpeg](https://ffmpeg.org/)

## Features

- Automatically record Twitch streams when a streamer goes online.
- Save recordings to your local machine.
- Prune old files after a specified number of days.
- Optional feature to upload recorded streams to a network drive.
- Enhanced resource monitoring to prevent system overloads.
- **Real-time monitoring dashboard** with live stats.
- **Systemd service** for auto-start and crash recovery.

## Installation

1. Install Python 3.8 or newer from [Python.org](https://www.python.org/downloads/).

2. Install the required Python packages:
   ```bash
   pip install -r requirements.txt
   ```

3. (Optional) Download FFmpeg from [FFmpeg.org](https://ffmpeg.org/download.html) and add the binary to your system's PATH.

## Configuration

Copy the example config and update with your preferences:

```bash
cp config/config.example.json config/config.json
```

Edit `config/config.json`:

- `root_path`: Directory for recorded and processed files.
- `username`: Twitch username.
- `client_id`: Your Twitch client ID.
- `client_secret`: Your Twitch client secret.
- `ffmpeg_path`: Path to FFmpeg executable (if not in PATH).
- `disable_ffmpeg`: Disable FFmpeg processing (true/false).
- `refresh_interval`: Interval in seconds for online checks.
- `stream_quality`: Desired quality of recorded streams.
- `prune_after_days`: Days after which to delete old files.
- `upload_to_network_drive`: Enable uploading to network drive (true/false).
- `network_drive_path`: Path for network drive uploads.

## Usage

1. Ensure Python 3.8+ is installed.
2. Install required packages: `pip install -r requirements.txt`.
3. Configure `config/config.json`.
4. Run the script: `python twitch-recorder.py`.

Command-line arguments to override `config/config.json`:

```bash
python twitch_recorder.py -u <username> -q <quality> [--disable-ffmpeg]
```

- `-u` or `--username`: Twitch username to monitor.
- `-q` or `--quality`: Stream quality (e.g., "best", "1080p60").
- `--disable-ffmpeg`: Disable FFmpeg processing.

## Logging

Logs events to `twitch-recorder.log`. Change log level with `-l` or `--log`:

```bash
python twitch_recorder.py -l DEBUG
```

## Monitoring Dashboard

Use the live dashboard to monitor recordings:

```bash
# Real-time dashboard with in-place updates
./scripts/dashboard-live.sh

# Standard dashboard
./scripts/dashboard.sh

# Auto-refreshing every 10 seconds
./scripts/dashboard-watch.sh
```

See [docs/MONITORING.md](docs/MONITORING.md) for details.

## Running as a Service

To run automatically on boot with crash recovery:

```bash
cd systemd
sudo bash install.sh
```

See [docs/SYSTEMD_SETUP.md](docs/SYSTEMD_SETUP.md) for details.

## License

This project is under the MIT License. See [LICENSE](LICENSE) for details.
