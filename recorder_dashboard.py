"""A read-only, low-overhead curses dashboard for the Twitch recorder (Python 3.7+)."""
import argparse
import collections
import curses
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import textwrap
import time
from pathlib import Path

import psutil

ANSI = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')
NAME = re.compile(r'^(.+?) - (\d{4}-\d{2}-\d{2} \d{2}h\d{2}m\d{2}s) - (.+)\.mp4$')
STAGES = ('All', 'Raw', 'Processed', 'Stitched', 'Failed')
TABS = ('Overview', 'Recordings', 'Activity', 'Health')


def clean(text):
    return ''.join(c for c in ANSI.sub('', str(text)) if c >= ' ' or c == '\t').replace('\t', ' ')


def human_bytes(value):
    if value is None:
        return '--'
    value = float(value)
    for unit in ('B', 'KiB', 'MiB', 'GiB', 'TiB'):
        if abs(value) < 1024 or unit == 'TiB':
            return ('%.1f %s' if unit != 'B' else '%.0f %s') % (value, unit)
        value /= 1024


def elapsed(value):
    seconds = max(0, int(value))
    hours, rem = divmod(seconds, 3600)
    minutes, seconds = divmod(rem, 60)
    return '%dh %02dm' % (hours, minutes) if hours else '%dm %02ds' % (minutes, seconds)


def display_time(epoch, timezone='America/New_York'):
    if epoch is None:
        return '--'
    # Python 3.7 on the Pi has no zoneinfo. The single-threaded dashboard restores
    # the system zone after formatting, so log timestamps retain their source zone.
    original = os.environ.get('TZ')
    try:
        if hasattr(time, 'tzset'):
            os.environ['TZ'] = timezone
            time.tzset()
        return datetime.datetime.fromtimestamp(epoch).strftime('%Y-%m-%d %H:%M:%S')
    finally:
        if hasattr(time, 'tzset'):
            if original is None:
                os.environ.pop('TZ', None)
            else:
                os.environ['TZ'] = original
            time.tzset()


def option(args, name):
    try:
        return args[args.index(name) + 1]
    except (ValueError, IndexError):
        return None


def absolute(path, cwd):
    if not path:
        return None
    p = Path(path)
    return str(p if p.is_absolute() else Path(cwd) / p)


class LogTail:
    def __init__(self):
        self.path = None
        self.identity = None
        self.position = 0
        self.partial = b''
        self.lines = collections.deque(maxlen=250)
        self.eventsub = None

    def read(self, path):
        if path is None:
            return
        try:
            stat = path.stat()
            identity = (str(path), stat.st_ino)
            reset = identity != self.identity or stat.st_size < self.position
            if reset:
                self.lines.clear()
                self.eventsub = None
                self.partial = b''
                self.position = max(0, stat.st_size - 65536)
                self.identity = identity
            with path.open('rb') as source:
                source.seek(self.position)
                # Skip old output if the recorder wrote more than one bounded read.
                if stat.st_size - self.position > 65536:
                    source.seek(stat.st_size - 65536)
                    self.partial = b''
                    reset = True
                data = source.read(65536)
                self.position = source.tell()
            if reset and self.position > len(data):
                data = data.split(b'\n', 1)[-1]
            chunks = (self.partial + data).split(b'\n')
            self.partial = chunks.pop()
            for raw in chunks:
                line = clean(raw.decode('utf-8', errors='replace'))
                if not line:
                    continue
                self.lines.append(line)
                if 'EventSub connected' in line or 'EventSub connection migrated' in line:
                    self.eventsub = ('Connected', line[:23])
                elif 'EventSub unavailable' in line or 'EventSub subscription revoked' in line:
                    self.eventsub = ('Unavailable', line[:23])
            self.path = str(path)
        except OSError:
            pass


class Collector:
    def __init__(self, base, config_path=None, inventory_interval=30):
        self.base = Path(base).resolve()
        self.config_path = Path(config_path) if config_path else self.base / 'config/config.json'
        if not config_path and not self.config_path.exists():
            self.config_path = self.base / 'config.json'
        self.config = json.loads(self.config_path.read_text())
        self.root = Path(self.config.get('root_path', './recordings'))
        if not self.root.is_absolute():
            self.root = self.base / self.root
        self.root = self.root.resolve()
        self.channels = self.config.get('usernames', [])
        self.timezone = self.config.get('dashboard_timezone', 'America/New_York')
        self.inventory_interval = inventory_interval
        self.catalog = []
        self.catalog_at = 0
        self.catalog_errors = []
        self.tail = LogTail()
        self.log_at = 0
        self.log_path = None
        self.service_at = 0
        self.service = {}
        self.previous_sizes = {}
        self.snapshot_data = {}
        psutil.cpu_percent(interval=None)

    def inventory(self, now, force=False):
        if not force and now - self.catalog_at < self.inventory_interval:
            return
        entries, errors = [], []
        for folder, stage in (('recorded', 'Raw'), ('processed', 'Processed'), ('failed', 'Failed')):
            directory = self.root / folder
            if not directory.exists():
                continue
            def scan_error(exc):
                errors.append('Cannot scan %s' % exc.filename)
            for parent, dirs, files in os.walk(str(directory), onerror=scan_error):
                dirs[:] = [name for name in dirs if not name.startswith('.')]
                for name in files:
                    if name.startswith('.') or not name.endswith('.mp4'):
                        continue
                    path = Path(parent) / name
                    try:
                        stat = path.stat()
                        relative = path.relative_to(directory)
                        channel = relative.parts[0] if len(relative.parts) > 1 else 'unknown'
                        kind = 'Stitched' if 'stitched' in relative.parts[:-1] else stage
                        match = NAME.match(name)
                        title = match[3] if match else path.stem
                        if title.endswith(' - stitched'):
                            title = title[:-11]
                        entries.append(dict(path=str(path), name=name, channel=channel,
                            stage=kind, size=stat.st_size, modified=stat.st_mtime,
                            title=title,
                            compressed=Path(str(path)+'.compressed').exists(),
                            upload_pending=Path(str(path)+'.upload-pending').exists()))
                    except OSError:
                        continue  # File may be moving between processing stages.
        self.catalog = sorted(entries, key=lambda row: row['modified'], reverse=True)
        self.catalog_errors, self.catalog_at = errors, now

    def logs(self, now):
        if now - self.log_at >= 15 or self.log_path is None:
            paths = list((self.base / 'logs').glob('twitch-recorder-*.log'))
            legacy = self.base / 'twitch-recorder.log'
            if legacy.exists():
                paths.append(legacy)
            try:
                self.log_path = max(paths, key=lambda p: p.stat().st_mtime) if paths else None
            except OSError:
                self.log_path = None
            self.log_at = now
        self.tail.read(self.log_path)

    def service_status(self, now):
        if now - self.service_at < 15:
            return
        self.service_at = now
        if sys.platform != 'linux' or not shutil.which('systemctl'):
            return
        candidates = [self.config.get('service_name', 'recordtwitch'), 'twitch-recorder']
        for unit in dict.fromkeys(candidates):
            try:
                result = subprocess.run(['systemctl', 'show', unit, '--no-pager',
                    '-p', 'LoadState', '-p', 'ActiveState', '-p', 'SubState',
                    '-p', 'NRestarts', '-p', 'MainPID', '-p', 'MemoryCurrent', '-p', 'MemoryMax'],
                    capture_output=True, text=True, timeout=2)
                data = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
                if data.get('LoadState') == 'loaded':
                    self.service = dict(data, unit=unit)
                    return
            except (OSError, subprocess.TimeoutExpired):
                continue
        self.service = {}

    def processes(self, now):
        records, candidates = [], []
        recorder_ids = set()
        for process in psutil.process_iter(['pid', 'ppid', 'name', 'cmdline', 'create_time']):
            try:
                info = process.info
                args = info.get('cmdline') or []
                if any(Path(arg).name == 'twitch-recorder.py' for arg in args[:3]):
                    script = next(arg for arg in args[:3] if Path(arg).name == 'twitch-recorder.py')
                    cwd = process.cwd()
                    if Path(absolute(script, cwd)).resolve().parent != self.base:
                        continue
                    recorder_ids.add(info['pid'])
                    records.append(dict(pid=info['pid'], started=info['create_time'],
                                        cpu=process.cpu_percent(), memory=process.memory_info().rss))
                elif any(Path(arg).name in ('streamlink', 'ffmpeg') for arg in args[:3]):
                    candidates.append((process, args, info))
            except (psutil.Error, OSError, ValueError):
                continue
        jobs = []
        current = {}
        for process, args, info in candidates:
            try:
                cwd = process.cwd()
                if info['ppid'] not in recorder_ids and Path(cwd).resolve() != self.base:
                    continue
                recording = any(Path(arg).name == 'streamlink' for arg in args[:3])
                if (recording and not option(args, '-o')) or (not recording and not option(args, '-i')):
                    continue
                output = absolute(option(args, '-o') if recording else args[-1], cwd)
                source = absolute(option(args, '-i'), cwd)
                kind = 'Recording' if recording else 'Stitching' if option(args, '-f') == 'concat' else (
                    'Compressing' if '-crf' in args else 'Remuxing')
                inputs = [source] if source else []
                if kind == 'Stitching' and source:
                    try:
                        concat = Path(source)
                        if not concat.exists() and sys.platform == 'linux':
                            concat = Path('/proc/%s/root' % info['pid']) / source.lstrip('/')
                        inputs = []
                        for line in concat.read_text().splitlines():
                            match = re.fullmatch(r"file '(.+)'", line)
                            if match:
                                alias = Path(match[1])
                                if not alias.exists() and sys.platform == 'linux':
                                    alias = Path('/proc/%s/root' % info['pid']) / match[1].lstrip('/')
                                inputs.append(os.readlink(str(alias)) if alias.is_symlink() else str(alias))
                    except OSError:
                        inputs = []
                channel = next((arg.split('twitch.tv/', 1)[1].split('/')[0] for arg in args if 'twitch.tv/' in arg), None)
                size = Path(output).stat().st_size if output and Path(output).is_file() else 0
                key = (info['pid'], info['create_time'], output)
                previous = self.previous_sizes.get(key)
                rate = max(0, (size-previous[0])/(now-previous[1])) if previous and now > previous[1] else None
                last_growth = now if not previous or size > previous[0] else previous[2]
                current[key] = (size, now, last_growth)
                if not channel and output:
                    parts = Path(output).parts
                    channel = next((name for name in self.channels if name in parts), None)
                jobs.append(dict(pid=info['pid'], kind=kind, channel=channel or '--',
                    source=source, output=output, size=size, rate=rate, elapsed=now-info['create_time'],
                    inputs=inputs, no_growth=now-last_growth,
                    cpu=process.cpu_percent(), memory=process.memory_info().rss))
            except (psutil.Error, OSError, ValueError):
                continue
        self.previous_sizes = current
        return records, jobs

    def snapshot(self, force=False):
        now = time.time()
        self.inventory(now, force)
        self.logs(now)
        self.service_status(now)
        records, jobs = self.processes(now)
        memory = psutil.virtual_memory()
        storage = self.root if self.root.exists() else self.base
        disk = psutil.disk_usage(str(storage))
        temperature = None
        try:
            thermal = Path('/sys/class/thermal/thermal_zone0/temp')
            if thermal.exists():
                temperature = float(thermal.read_text()) / 1000
        except (OSError, ValueError):
            pass
        state = 'Disabled'
        if self.config.get('eventsub_enabled'):
            state = self.tail.eventsub[0] if self.tail.eventsub else 'Unknown'
            if not records:
                state = 'Recorder stopped'
            elif self.tail.eventsub:
                try:
                    reported = datetime.datetime.strptime(self.tail.eventsub[1], '%Y-%m-%d %H:%M:%S,%f').timestamp()
                    if reported < max(r['started'] for r in records) - 3:
                        state = 'Unknown (previous recorder session)'
                except ValueError:
                    state = 'Unknown'
        counts = collections.Counter(row['stage'] for row in self.catalog)
        alerts = list(self.catalog_errors)
        if not records:
            alerts.append('Recorder is not running')
        if self.config.get('eventsub_enabled') and state != 'Connected':
            alerts.append('EventSub %s; status polling is the fallback' % state.lower())
        if disk.percent >= 85:
            alerts.append('Disk space is low: %.1f%% used' % disk.percent)
        if memory.percent >= 85:
            alerts.append('Memory usage is high: %.1f%%' % memory.percent)
        if temperature is not None and temperature >= 75:
            alerts.append('CPU temperature is high: %.1f C' % temperature)
        if counts['Failed']:
            alerts.append('%d quarantined recording(s) need attention' % counts['Failed'])
        self.snapshot_data = dict(now=now, hostname=os.uname().nodename if hasattr(os, 'uname') else 'localhost',
            base=str(self.base), root=str(self.root), timezone=self.timezone, recorder=records,
            jobs=jobs, eventsub=state, eventsub_reported=self.tail.eventsub[1] if self.tail.eventsub else None,
            poll_interval=self.config.get('refresh_interval', 60), service=self.service,
            cpu=psutil.cpu_percent(interval=None), memory_percent=memory.percent,
            memory_available=memory.available, memory_total=memory.total, disk_percent=disk.percent,
            disk_free=disk.free, disk_total=disk.total, uptime=now-psutil.boot_time(),
            temperature=temperature, load=list(os.getloadavg()) if hasattr(os, 'getloadavg') else [],
            catalog=self.catalog, catalog_at=self.catalog_at, counts=dict(counts),
            logs=list(self.tail.lines), log_path=self.tail.path, alerts=alerts)
        return self.snapshot_data


def summary_lines(data):
    state = 'RUNNING' if data['recorder'] else 'STOPPED'
    lines = ['TWITCH RECORDER  %s  %s' % (data['hostname'], display_time(data['now'], data['timezone'])),
        'Recorder: %s | EventSub: %s | Outage polling setting: %ss' % (state, data['eventsub'], data['poll_interval']),
        'CPU %.1f%% | RAM %.1f%% | Disk %.1f%% (%s free) | Uptime %s' % (
            data['cpu'], data['memory_percent'], data['disk_percent'], human_bytes(data['disk_free']), elapsed(data['uptime'])),
        'Files: ' + ' | '.join('%s %d' % (stage, data['counts'].get(stage, 0)) for stage in STAGES[1:])]
    for job in data['jobs']:
        lines.append('%s %s | PID %s | %s | %s written | %s' % (job['kind'],job['channel'],job['pid'],elapsed(job['elapsed']),human_bytes(job['size']),job['output']))
    lines += ['ATTENTION: '+alert for alert in data['alerts']]
    return lines


class Dashboard:
    def __init__(self, collector, refresh):
        self.collector, self.refresh = collector, refresh
        self.tab, self.channel, self.stage = 0, 'All', 'All'
        self.query, self.sort = '', 'newest'
        self.selection, self.scroll = 0, 0
        self.paused, self.help, self.detail = False, False, False
        self.data = {}
        self.searching = False
        self.selected_path = None
        self.problem = None

    def rows(self):
        result = [row for row in self.data.get('catalog', []) if
                  (self.channel == 'All' or row['channel'] == self.channel) and
                  (self.stage == 'All' or row['stage'] == self.stage) and
                  self.query.lower() in (row['name']+' '+row['channel']).lower()]
        return sorted(result, key=lambda row: row['size'] if self.sort == 'largest' else row['modified'], reverse=True)

    def text(self, screen, y, x, value, attr=0):
        height, width = screen.getmaxyx()
        if y < 0 or y >= height or x >= width - 1:
            return
        try:
            screen.addnstr(y, x, clean(value), max(0, width-x-1), attr)
        except curses.error:
            pass

    def render(self, screen):
        screen.erase()
        h, w = screen.getmaxyx()
        if h < 12 or w < 60:
            self.text(screen, 0, 0, 'Terminal too small. Resize to at least 60 columns x 12 rows.')
            self.text(screen, 2, 0, 'q: quit')
            screen.refresh()
            return
        d = self.data
        self.text(screen,0,1,'TWITCH RECORDER  |  '+d['hostname'],curses.A_BOLD | curses.color_pair(1))
        self.text(screen,0,max(30,w-34),display_time(d['now'],d['timezone']) + ('  PAUSED' if self.paused else '  LIVE'))
        self.text(screen,1,1,'  '.join(('[%d %s]' if index == self.tab else ' %d %s ') % (index+1,name) for index,name in enumerate(TABS)),curses.A_BOLD)
        self.text(screen,2,1,'Recorder %s  |  EventSub %s  |  %d job(s)  |  %s free' % (
            'RUNNING' if d['recorder'] else 'STOPPED',d['eventsub'],len(d['jobs']),human_bytes(d['disk_free'])))
        screen.hline(3,1,'-',w-2)
        if self.tab == 0:
            lines = summary_lines(d)[2:4] + ['ATTENTION: '+alert for alert in d['alerts']]
            lines += ['', 'CURRENT WORK']
            if not d['jobs']:
                lines.append('Idle: waiting for a stream or the next processing cycle')
            for job in d['jobs']:
                lines += [job['kind'].upper()+'  '+job['channel']+'  |  elapsed '+elapsed(job['elapsed']),
                          'Written '+human_bytes(job['size'])+'  |  growth '+human_bytes(job['rate'])+'/s  |  CPU %.1f%%' % job['cpu']]
                for path in job['inputs'] or [job['source'] or '--']:
                    lines += textwrap.wrap('Input: '+str(path),width=w-3)
                lines += textwrap.wrap('Output: '+str(job['output']),width=w-3)
            lines += ['', 'RECENT FILES']
            for row in d['catalog'][:5]:
                lines.append('%-9s %-14s %-10s %s' % (row['stage'],row['channel'],human_bytes(row['size']),row['title']))
            lines += ['', 'LATEST EVENTS']+d['logs'][-5:]
            self.draw_lines(screen,lines,4,h-3)
        elif self.tab == 1:
            rows = self.rows()
            if self.selected_path:
                match = next((index for index,row in enumerate(rows) if row['path'] == self.selected_path),None)
                if match is not None:
                    self.selection = match
            self.selection = max(0,min(self.selection,len(rows)-1))
            self.selected_path = rows[self.selection]['path'] if rows else None
            self.text(screen,4,1,'Channel: %s  |  Stage: %s  |  Sort: %s  |  %d files' % (self.channel,self.stage,self.sort,len(rows)))
            self.text(screen,5,1,('Search: '+self.query+'_' if self.searching else 'Filter: '+(self.query or '(none)')))
            if self.detail and rows:
                row = rows[self.selection]
                details = ['FILE DETAILS', '',row['name'],'', 'Channel: '+row['channel'],'Stage: '+row['stage'],
                    'Size: '+human_bytes(row['size']),'Updated: '+display_time(row['modified'],d['timezone'])+' '+d['timezone'],
                    'Compressed: '+str(row['compressed']),'Upload pending: '+str(row['upload_pending']), '', 'Full path:',row['path']]
                try:
                    manifest = Path(row['path']+'.parts.json')
                    if manifest.exists():
                        details += ['', 'JOINED PARTS']+json.loads(manifest.read_text())
                except (OSError,ValueError):
                    details.append('Parts manifest unavailable')
                self.draw_lines(screen,details,7,h-3)
            else:
                self.text(screen,7,1,'STAGE      CHANNEL         SIZE        UPDATED           TITLE' if w >= 100 else
                          'STAGE      CHANNEL      SIZE       TITLE',curses.A_BOLD)
                visible = max(1,h-11)
                start = max(0,self.selection-visible+1)
                for offset,row in enumerate(rows[start:start+visible]):
                    selected = start+offset == self.selection
                    if w >= 100:
                        line = '%-10s %-15s %-11s %-17s %s' % (row['stage'],row['channel'][:14],human_bytes(row['size']),
                            display_time(row['modified'],d['timezone'])[:16],row['title'])
                    else:
                        line = '%-10s %-12s %-10s %s' % (row['stage'],row['channel'][:12],human_bytes(row['size']),row['title'])
                    self.text(screen,8+offset,1,line,curses.A_REVERSE if selected else 0)
                if not rows:
                    self.text(screen,9,1,'No files match these filters.')
        elif self.tab == 2:
            self.draw_lines(screen,list(reversed(d['logs'])),4,h-3)
        else:
            service = d['service']
            lines = ['SYSTEM HEALTH', '', 'CPU usage: %.1f%%  |  load %s' % (d['cpu'],', '.join('%.2f'%v for v in d['load'])),
                'Memory: %.1f%% used  |  %s available / %s total' % (d['memory_percent'],human_bytes(d['memory_available']),human_bytes(d['memory_total'])),
                'Disk: %.1f%% used  |  %s free / %s total' % (d['disk_percent'],human_bytes(d['disk_free']),human_bytes(d['disk_total'])),
                'Temperature: '+('%.1f C'%d['temperature'] if d['temperature'] is not None else 'unavailable'),
                'System uptime: '+elapsed(d['uptime']), '', 'RECORDER AND NOTIFICATIONS',
                'Service: '+service.get('unit','process detection')+'  '+service.get('ActiveState',''),
                'Service restarts: '+service.get('NRestarts','--'),
                'EventSub last reported state: '+d['eventsub'],
                'EventSub report timestamp (source log zone): '+str(d['eventsub_reported'] or '--'),
                'Fallback polling setting: %ss'%d['poll_interval'],
                'Recorder PID(s): '+', '.join(str(r['pid']) for r in d['recorder']),
                'Recorder RAM: '+human_bytes(sum(r['memory'] for r in d['recorder'])), '', 'DATA SOURCES',
                'Recordings: '+d['root'],'Log: '+str(d['log_path'] or 'not found'),
                'Catalog scanned: '+display_time(d['catalog_at'],d['timezone']),
                'Displayed file timestamps: '+d['timezone'], '', 'ATTENTION']+(d['alerts'] or ['No current health warnings'])
            self.draw_lines(screen,lines,4,h-3)
        if self.help:
            screen.erase()
            self.draw_lines(screen,['KEYBOARD SHORTCUTS','', '1-4 / Tab      Switch view',
                'Up/Down j/k    Select file or scroll', 'PgUp/PgDn      Scroll a page',
                'Enter          Open/close file details', '/              Search filenames and channels',
                'c              Cycle channel filter', 'g              Cycle Raw/Processed/Stitched/Failed',
                's              Sort newest / largest', 'r              Refresh all data now',
                'Space          Pause/resume display', 'Esc            Close details / clear search',
                '?              Toggle help', 'q              Quit', '',
                'Dashboard is read-only. File inventory refreshes every 30 seconds.',
                'Output growth shows bytes written, not an estimated completion percentage.'],1,h-2)
        self.text(screen,h-2,1,self.problem or ('/: search  c: channel  g: stage  s: sort  Enter: details  r: refresh  Space: pause  ?: help  q: quit'))
        screen.refresh()

    def draw_lines(self,screen,lines,start,end):
        width=screen.getmaxyx()[1]
        lines=[part for line in lines for part in (textwrap.wrap(clean(line),width=max(1,width-3)) or [''])]
        visible=max(1,end-start)
        self.scroll=max(0,min(self.scroll,max(0,len(lines)-visible)))
        for offset,line in enumerate(lines[self.scroll:self.scroll+visible]):
            self.text(screen,start+offset,1,line)

    def key(self, key):
        if self.searching:
            if key in (10,13,27):
                self.searching=False
            elif key in (curses.KEY_BACKSPACE,127,8):
                self.query=self.query[:-1]
            elif 32 <= key < 127:
                self.query+=chr(key)
            self.selection=0;self.selected_path=None
            return True
        if key in (ord('q'),3):
            return False
        if key == ord('?'):
            self.help=not self.help
        elif key == 9:
            self.tab=(self.tab+1)%4;self.scroll=0;self.detail=False
        elif ord('1') <= key <= ord('4'):
            self.tab=key-ord('1');self.scroll=0;self.detail=False
        elif key in (curses.KEY_DOWN,ord('j'),curses.KEY_NPAGE,curses.KEY_UP,ord('k'),curses.KEY_PPAGE):
            amount=10 if key in (curses.KEY_NPAGE,curses.KEY_PPAGE) else 1
            direction=-1 if key in (curses.KEY_UP,ord('k'),curses.KEY_PPAGE) else 1
            if self.tab==1 and not self.detail:
                self.selection+=direction*amount;self.selected_path=None
            else:
                self.scroll+=direction*amount
        elif key in (10,13) and self.tab==1:
            self.detail=not self.detail;self.scroll=0
        elif key==ord('/'):
            self.tab=1;self.searching=True;self.detail=False
        elif key==27:
            self.detail=False;self.query='';self.scroll=0
        elif key==ord('c'):
            channels=['All']+list(self.collector.channels)
            self.channel=channels[(channels.index(self.channel)+1)%len(channels)];self.selection=0;self.selected_path=None
        elif key==ord('g'):
            self.stage=STAGES[(STAGES.index(self.stage)+1)%len(STAGES)];self.selection=0;self.selected_path=None
        elif key==ord('s'):
            self.sort='largest' if self.sort=='newest' else 'newest';self.selection=0;self.selected_path=None
        elif key==ord(' '):
            self.paused=not self.paused
        elif key==ord('r'):
            self.data=self.collector.snapshot(force=True);self.problem=None
        return True

    def run(self,screen):
        try:
            curses.curs_set(0)
        except curses.error:
            pass
        if curses.has_colors():
            curses.start_color()
            try:
                curses.use_default_colors()
                curses.init_pair(1,curses.COLOR_CYAN,-1)
            except curses.error:
                curses.init_pair(1,curses.COLOR_CYAN,curses.COLOR_BLACK)
        screen.timeout(200)
        self.data=self.collector.snapshot(force=True)
        next_update=time.monotonic()+self.refresh
        while True:
            if not self.paused and time.monotonic() >= next_update:
                try:
                    self.data=self.collector.snapshot();self.problem=None
                except (OSError,psutil.Error) as exc:
                    self.problem='Refresh unavailable: '+str(exc)
                next_update=time.monotonic()+self.refresh
            self.render(screen)
            key=screen.getch()
            if key != -1 and not self.key(key):
                break


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base',default=str(Path(__file__).resolve().parent))
    parser.add_argument('--config')
    parser.add_argument('--refresh',type=float,default=2)
    parser.add_argument('--once',action='store_true',help='Print a status snapshot without a terminal UI')
    parser.add_argument('--json',action='store_true',help='Print a machine-readable status snapshot')
    args=parser.parse_args(argv)
    try:
        collector=Collector(args.base,args.config)
        if args.once or args.json or not sys.stdin.isatty() or not sys.stdout.isatty():
            data=collector.snapshot(force=True)
            print(json.dumps(data,indent=2) if args.json else '\n'.join(summary_lines(data)))
        else:
            curses.wrapper(Dashboard(collector,max(1,args.refresh)).run)
        return 0
    except KeyboardInterrupt:
        return 0
    except (OSError,ValueError,psutil.Error,curses.error) as exc:
        print('Dashboard unavailable: '+str(exc),file=sys.stderr)
        return 1


if __name__=='__main__':
    sys.exit(main())
