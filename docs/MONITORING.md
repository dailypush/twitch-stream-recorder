# Recorder TUI

SSH into the Pi and launch the consolidated dashboard:

```bash
ssh pi@raspberrypi.local
dashboard
```

The repository launcher is `./scripts/dashboard.sh`. The former live and watch
launchers open the same TUI; `dashboard-watch.sh 10` still sets a ten-second refresh.

| View | What it shows |
| --- | --- |
| 1 Overview | Recorder and EventSub status, active Streamlink/FFmpeg jobs, actual output growth, recent files and events |
| 2 Recordings | Raw, processed, stitched and failed files; searchable titles, channel and stage filters, full paths and joined parts |
| 3 Activity | Latest dated recorder log, newest entries first |
| 4 Health | CPU, RAM, disk, temperature, uptime, systemd restarts, notification status and data sources |

Use **1–4** or **Tab** to change views; **Up/Down** or **j/k** to select and
scroll; **PgUp/PgDn** to move a page. In Recordings, **/** searches,
**c** cycles channels, **g** cycles stages, **s** switches newest/largest sorting,
and **Enter** opens file details. **Esc** closes details or clears search.
**r** refreshes immediately, **Space** pauses the display, **?** shows help,
and **q** exits.

Status refreshes every two seconds. File inventories are cached for thirty
seconds, logs are read incrementally, and service status is cached for fifteen
seconds. This dashboard is read-only and makes no Twitch API requests. It reads
configured recording folders, recorder processes, systemd and the latest recorder
log; notification health is explicitly the last state reported in that log.

Processing shows elapsed time, input/output paths, bytes written and output
growth rather than guessing a completion percentage. Originals and stitched
outputs appear as separate files because the recorder retains both. File dates
show filesystem modification time, labeled Updated; displayed times default to
America/New_York and can be changed with `dashboard_timezone` in recorder config.
Source log timestamps retain the Pi's log timezone.

For a one-time snapshot or scriptable JSON:

```bash
./scripts/dashboard.sh --once
./scripts/dashboard.sh --json
./scripts/dashboard.sh --refresh 5
```

A noninteractive invocation automatically prints a snapshot. The interactive TUI
requires a terminal at least 60 columns by 12 rows and uses Python's standard
`curses` module plus the project's existing `psutil` dependency. If launching
remotely in one command, allocate a terminal:

```bash
ssh -t pi@raspberrypi.local /home/pi/twitch-recoder/twitch-stream-recorder/scripts/dashboard.sh
```
