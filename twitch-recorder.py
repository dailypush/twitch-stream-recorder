import datetime
import enum
import getopt
import logging
import os
import subprocess
import sys
import shutil
import time
import requests
import psutil
import json
import threading
import signal
from concurrent.futures import ThreadPoolExecutor, as_completed
from tqdm import tqdm
from pathlib import Path
from colorama import init, Fore, Style

init(autoreset=True)

class TwitchResponseStatus(enum.Enum):
    ONLINE = 0
    OFFLINE = 1
    NOT_FOUND = 2
    UNAUTHORIZED = 3
    ERROR = 4

class TwitchRecorder:
    def __init__(self):
        # Load configuration with error handling
        try:
            # Try config/config.json first, fall back to config.json
            config_path = "config/config.json" if os.path.exists("config/config.json") else "config.json"
            with open(config_path, "r") as config_file:
                config_data = json.load(config_file)
        except FileNotFoundError:
            logging.error("config.json not found. Please create a configuration file.")
            sys.exit(1)
        except json.JSONDecodeError as e:
            logging.error(f"Invalid JSON in config.json: {e}")
            sys.exit(1)
        except Exception as e:
            logging.error(f"Error loading config.json: {e}")
            sys.exit(1)

        # Global configuration with validation
        self.ffmpeg_path = config_data.get("ffmpeg_path", "ffmpeg")
        self.disable_ffmpeg = config_data.get("disable_ffmpeg", False)
        self.refresh = max(10, config_data.get("refresh_interval", 60))  # Minimum 10 seconds
        self.root_path = config_data.get("root_path", "./recordings")
        self.max_concurrent_recordings = max(1, config_data.get("max_concurrent_recordings", 2))
        self.cpu_threshold = config_data.get("cpu_threshold", 80)
        self.memory_threshold = config_data.get("memory_threshold", 80)
        self.check_cpu_threshold = config_data.get("check_cpu_threshold", 50)
        
        # Thread-safe counter and locks
        self._active_recordings_lock = threading.Lock()
        self._active_recordings = 0
        self._recording_processes = {}  # Track active processes
        self._shutdown_event = threading.Event()

        # User configuration
        self.prune_after_days = config_data.get("prune_after_days", 30)
        self.upload_to_network_drive_enabled = config_data.get("upload_to_network_drive", False)
        self.network_drive_path = config_data.get("network_drive_path", "")
        self.usernames = config_data.get("usernames", [])
        self.quality = config_data.get("stream_quality", "best")

        # Validate required fields
        if not self.usernames:
            logging.error("No usernames specified in config.json")
            sys.exit(1)

        # Twitch configuration
        self.client_id = config_data.get("client_id", "")
        self.client_secret = config_data.get("client_secret", "")
        if not self.client_id or not self.client_secret:
            logging.error("Missing client_id or client_secret in config.json")
            sys.exit(1)

        self.token_url = f"https://id.twitch.tv/oauth2/token?client_id={self.client_id}&client_secret={self.client_secret}&grant_type=client_credentials"
        self.url = "https://api.twitch.tv/helix/streams"
        self.access_token = None
        self.token_expires_at = 0
        self.fetch_access_token()

        # Setup signal handlers for graceful shutdown
        signal.signal(signal.SIGINT, self._signal_handler)
        signal.signal(signal.SIGTERM, self._signal_handler)

    def _signal_handler(self, signum, frame):
        logging.info("Shutdown signal received. Cleaning up...")
        self._shutdown_event.set()
        self._cleanup_processes()

    def _cleanup_processes(self):
        """Clean up any running recording processes"""
        with self._active_recordings_lock:
            for username, process in self._recording_processes.items():
                if process and process.poll() is None:
                    logging.info(f"Terminating recording process for {username}")
                    try:
                        process.terminate()
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                    except Exception as e:
                        logging.error(f"Error terminating process for {username}: {e}")
            self._recording_processes.clear()

    @property
    def active_recordings(self):
        with self._active_recordings_lock:
            return self._active_recordings

    def _increment_recordings(self):
        with self._active_recordings_lock:
            self._active_recordings += 1

    def _decrement_recordings(self):
        with self._active_recordings_lock:
            self._active_recordings = max(0, self._active_recordings - 1)

    def can_start_new_recording(self):
        if self.active_recordings >= self.max_concurrent_recordings:
            return False
        
        cpu_usage = psutil.cpu_percent(interval=1)
        memory_usage = psutil.virtual_memory().percent
        
        if cpu_usage > self.cpu_threshold or memory_usage > self.memory_threshold:
            logging.warning(f"High resource usage: CPU {cpu_usage}%, Memory {memory_usage}%")
            return False
        
        # Check available disk space (require at least 1GB free)
        try:
            disk_usage = psutil.disk_usage(self.root_path)
            free_gb = disk_usage.free / (1024**3)
            if free_gb < 1:
                logging.warning(f"Low disk space: {free_gb:.2f}GB available")
                return False
        except Exception as e:
            logging.error(f"Error checking disk space: {e}")
            return False
        
        return True

    def fetch_access_token(self):
        """Fetch or refresh access token with proper error handling"""
        try:
            current_time = time.time()
            # Refresh token if it expires in the next 5 minutes
            if self.access_token and current_time < (self.token_expires_at - 300):
                return self.access_token

            logging.info("Fetching new access token")
            token_response = requests.post(self.token_url, timeout=15)
            token_response.raise_for_status()
            token_data = token_response.json()
            
            self.access_token = token_data["access_token"]
            expires_in = token_data.get("expires_in", 3600)
            self.token_expires_at = current_time + expires_in
            
            logging.info(f"Access token refreshed, expires in {expires_in} seconds")
            return self.access_token
        except Exception as e:
            logging.error(f"Failed to fetch access token: {e}")
            raise

    def run(self):
        """Main run loop with proper threading"""
        paths = self.create_directories()
        
        # Don't process old recordings at startup - do it during idle time
        # Just prune old files
        for username in self.usernames:
            recorded_path, processed_path = paths[username]
            self.prune_old_files(recorded_path)
            self.prune_old_files(processed_path)

        # Use ThreadPoolExecutor for concurrent recording checks
        with ThreadPoolExecutor(max_workers=min(len(self.usernames), 5)) as executor:
            while not self._shutdown_event.is_set():
                cpu_usage = psutil.cpu_percent(interval=1)
                
                if cpu_usage < self.check_cpu_threshold:
                    # Submit tasks for each username
                    future_to_username = {}
                    for username in self.usernames:
                        recorded_path, processed_path = paths[username]
                        future = executor.submit(self.check_and_record_user, username, recorded_path, processed_path)
                        future_to_username[future] = username
                    
                    # Wait for all tasks to complete or timeout
                    for future in as_completed(future_to_username, timeout=self.refresh):
                        username = future_to_username[future]
                        try:
                            future.result()
                        except Exception as e:
                            logging.error(f"Error in thread for {username}: {e}")
                    
                    # Process old recordings ONLY when idle (no active recordings)
                    if self._active_recordings == 0 and not self.disable_ffmpeg:
                        for username in self.usernames:
                            recorded_path, processed_path = paths[username]
                            self.process_previous_recordings(recorded_path, processed_path)
                else:
                    logging.warning(f"High CPU usage ({cpu_usage}%). Pausing new checks.")
                
                # Wait for next cycle
                if not self._shutdown_event.wait(timeout=self.refresh):
                    continue
                else:
                    break

        logging.info("Shutting down...")
        self._cleanup_processes()

    def check_and_record_user(self, username, recorded_path, processed_path):
        """Check and potentially record a single user"""
        try:
            logging.info(f"Checking {username}")
            status, info = self.check_user(username)
            
            if status == TwitchResponseStatus.NOT_FOUND:
                logging.error(f"{Fore.RED}Username {username} not found")
            elif status == TwitchResponseStatus.OFFLINE:
                logging.info(f"{Fore.YELLOW}{username} currently offline")
            elif status == TwitchResponseStatus.UNAUTHORIZED:
                logging.info(f"{Fore.RED}Unauthorized, refreshing access token")
                self.fetch_access_token()
            elif status == TwitchResponseStatus.ONLINE:
                if self.can_start_new_recording():
                    self.record_stream(username, info, recorded_path, processed_path)
                else:
                    logging.info(f"{Fore.YELLOW}Cannot start recording for {username} - resource limits")
        except Exception as e:
            logging.error(f"Error checking {username}: {e}")

    def create_directories(self):
        """Create necessary directories with proper error handling"""
        paths = {}
        try:
            for username in self.usernames:
                recorded_path = os.path.join(self.root_path, "recorded", username)
                processed_path = os.path.join(self.root_path, "processed", username)
                os.makedirs(recorded_path, exist_ok=True)
                os.makedirs(processed_path, exist_ok=True)
                paths[username] = (recorded_path, processed_path)
        except PermissionError:
            logging.error(f"Permission denied creating directories in {self.root_path}")
            sys.exit(1)
        except Exception as e:
            logging.error(f"Error creating directories: {e}")
            sys.exit(1)
        return paths

    def prune_old_files(self, path):
        """Prune old files with better error handling"""
        if self.prune_after_days <= 0:
            return
            
        try:
            now = datetime.datetime.now()
            for filepath in Path(path).glob('*'):
                if filepath.is_file():
                    file_modified_time = datetime.datetime.fromtimestamp(filepath.stat().st_mtime)
                    age_in_days = (now - file_modified_time).days
                    if age_in_days > self.prune_after_days:
                        try:
                            filepath.unlink()
                            logging.info(f"Deleted old file: {filepath}")
                        except Exception as e:
                            logging.error(f"Failed to delete {filepath}: {e}")
        except Exception as e:
            logging.error(f"Error during pruning in {path}: {e}")

    def process_previous_recordings(self, recorded_path, processed_path):
        """Process ONE existing recording per call (called during idle time only)"""
        try:
            video_files = [f for f in os.listdir(recorded_path) 
                          if os.path.isfile(os.path.join(recorded_path, f)) and f.endswith('.mp4')]
            
            # Only process ONE file at a time to avoid blocking for too long
            if video_files:
                filename = video_files[0]  # Just process the first one
                recorded_filename = os.path.join(recorded_path, filename)
                processed_filename = os.path.join(processed_path, filename)
                logging.info(f"Processing {filename} ({len(video_files)-1} remaining)")
                self.process_recorded_file(recorded_filename, processed_filename)
        except Exception as e:
            logging.error(f"Error processing previous recordings: {e}")

    def process_recorded_file(self, recorded_filename, processed_filename):
        """Process a single recorded file with proper error handling"""
        try:
            # Wait a moment to ensure file is not being written to
            time.sleep(2)
            
            # Check if file is still being written (size changing)
            initial_size = os.path.getsize(recorded_filename)
            time.sleep(1)
            final_size = os.path.getsize(recorded_filename)
            
            if initial_size != final_size:
                logging.warning(f"File {recorded_filename} still being written, skipping")
                return
            
            if self.disable_ffmpeg:
                logging.info(f"Moving: {recorded_filename}")
                shutil.move(recorded_filename, processed_filename)
            else:
                # Double check we're still idle before starting ffmpeg
                if self._active_recordings > 0:
                    logging.info(f"Stream recording started, postponing ffmpeg processing")
                    return
                    
                logging.info(f"Processing with ffmpeg: {recorded_filename}")
                if self.ffmpeg_copy_and_fix_errors(recorded_filename, processed_filename):
                    os.remove(recorded_filename)
                else:
                    logging.error(f"FFmpeg processing failed for {recorded_filename}")
                    return
            
            if self.upload_to_network_drive_enabled:
                self.upload_to_network_drive(processed_filename)
                
        except Exception as e:
            logging.error(f"Error processing file {recorded_filename}: {e}")

    def ffmpeg_copy_and_fix_errors(self, recorded_filename, processed_filename):
        """Run ffmpeg with H.264 compression and higher audio bitrate."""
        try:
            # Calculate reasonable timeout based on file size (1 hour per GB on slow devices)
            file_size_gb = os.path.getsize(recorded_filename) / (1024**3)
            timeout_seconds = max(3600, int(file_size_gb * 3600))  # At least 1 hour, scale with file size
            
            # Use fast copy for audio (avoid re-encoding issues) and moderate H.264 settings for Pi
            result = subprocess.run([
                self.ffmpeg_path, 
                "-err_detect", "ignore_err",
                "-i", recorded_filename,
                "-c:v", "libx264",           # H.264 codec for efficient compression
                "-crf", "28",                # Slightly lower quality (28 instead of 23) for speed on Pi
                "-preset", "medium",         # Medium preset (faster than slower for Raspberry Pi)
                "-c:a", "aac",               # Re-encode audio to AAC
                "-b:a", "128k",              # Reduced audio bitrate (DJ quality at 128k is sufficient)
                "-movflags", "+faststart",   # Optimize for streaming
                "-y",                        # Overwrite output file
                processed_filename
            ], capture_output=True, text=True, timeout=timeout_seconds)

            if result.returncode != 0:
                logging.error(f"FFmpeg failed for {recorded_filename}")
                logging.error(f"FFmpeg stderr: {result.stderr}")
                logging.error(f"FFmpeg stdout: {result.stdout}")
                return False
            logging.info(f"Successfully processed: {recorded_filename}")
            return True
        except subprocess.TimeoutExpired:
            logging.error(f"FFmpeg timeout ({timeout_seconds}s) processing {recorded_filename}")
            return False
        except Exception as e:
            logging.error(f"FFmpeg error: {e}")
            return False

    def check_user(self, username):
        """Check if user is streaming with token refresh"""
        # Proactively refresh token if needed
        self.fetch_access_token()
        
        headers = {"Client-ID": self.client_id, "Authorization": f"Bearer {self.access_token}"}
        try:
            response = requests.get(f"{self.url}?user_login={username}", headers=headers, timeout=15)
            
            if response.status_code == 401:
                # Try refreshing token once
                self.fetch_access_token()
                headers["Authorization"] = f"Bearer {self.access_token}"
                response = requests.get(f"{self.url}?user_login={username}", headers=headers, timeout=15)
            
            response.raise_for_status()
            info = response.json()
            return TwitchResponseStatus.ONLINE if info["data"] else TwitchResponseStatus.OFFLINE, info
            
        except requests.exceptions.RequestException as e:
            logging.error(f"Error checking user {username}: {e}")
            if hasattr(e, 'response') and e.response:
                if e.response.status_code == 401:
                    return TwitchResponseStatus.UNAUTHORIZED, None
                elif e.response.status_code == 404:
                    return TwitchResponseStatus.NOT_FOUND, None
            return TwitchResponseStatus.ERROR, None

    def upload_to_network_drive(self, processed_filename):
        """Upload to network drive with verification"""
        if not self.network_drive_path:
            return
            
        try:
            filename = os.path.basename(processed_filename)
            destination = os.path.join(self.network_drive_path, filename)
            
            # Ensure destination directory exists
            os.makedirs(os.path.dirname(destination), exist_ok=True)
            
            # Copy file
            shutil.copy2(processed_filename, destination)
            
            # Verify upload
            if os.path.exists(destination):
                src_size = os.path.getsize(processed_filename)
                dst_size = os.path.getsize(destination)
                if src_size == dst_size:
                    logging.info(f"Successfully uploaded: {destination}")
                else:
                    logging.error(f"Upload verification failed: size mismatch for {destination}")
            else:
                logging.error(f"Upload failed: {destination} not found after copy")
                
        except Exception as e:
            logging.error(f"Failed to upload to network drive: {e}")

    def record_stream(self, username, info, recorded_path, processed_path):
        """Record a stream with proper process management"""
        try:
            self._increment_recordings()
            
            channel = info["data"][0]
            timestamp = datetime.datetime.now().strftime('%Y-%m-%d %Hh%Mm%Ss')
            title = channel.get('title', 'Unknown')
            # Sanitize filename
            safe_title = "".join(c for c in title if c.isalnum() or c in [" ", "-", "_"])[:100]
            filename = f"{username} - {timestamp} - {safe_title}.mp4"
            
            recorded_filename = os.path.join(recorded_path, filename)
            processed_filename = os.path.join(processed_path, filename)

            logging.info(f"{Fore.GREEN}{username} online, starting recording")

            # Start streamlink process
            streamlink_cmd = [
                "streamlink", "--twitch-disable-ads", "--retry-streams", "5",
                f"twitch.tv/{username}", self.quality, "-o", recorded_filename
            ]
            
            streamlink_process = subprocess.Popen(
                streamlink_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE
            )
            
            # Store process for cleanup
            with self._active_recordings_lock:
                self._recording_processes[username] = streamlink_process

            # Monitor recording with improved progress tracking
            self._monitor_recording(streamlink_process, recorded_filename, filename)

            # Clean up process reference
            with self._active_recordings_lock:
                self._recording_processes.pop(username, None)

            # Don't process immediately - let it happen during idle time in main loop
            if os.path.exists(recorded_filename) and os.path.getsize(recorded_filename) > 0:
                logging.info(f"Recording completed for {username}, will process when idle")
            else:
                logging.warning(f"Recording file for {username} not found or empty")

        except Exception as e:
            logging.error(f"Error recording {username}: {e}")
        finally:
            self._decrement_recordings()

    def _monitor_recording(self, process, filename, display_name):
        """Monitor recording process with better progress display"""
        try:
            with tqdm(total=0, unit='B', unit_scale=True, desc=display_name[:50], ncols=100) as pbar:
                last_size = 0
                stalled_count = 0
                
                while process.poll() is None:
                    if self._shutdown_event.is_set():
                        process.terminate()
                        break
                        
                    if os.path.exists(filename):
                        current_size = os.path.getsize(filename)
                        if current_size > last_size:
                            pbar.total = current_size
                            pbar.n = current_size
                            pbar.refresh()
                            last_size = current_size
                            stalled_count = 0
                        else:
                            stalled_count += 1
                            if stalled_count > 12:  # 1 minute of no growth
                                logging.warning(f"Recording appears stalled for {display_name}")
                                stalled_count = 0
                    
                    time.sleep(5)
                
                # Final update
                if os.path.exists(filename):
                    final_size = os.path.getsize(filename)
                    pbar.total = final_size
                    pbar.n = final_size
                    pbar.refresh()
                    
        except Exception as e:
            logging.error(f"Error monitoring recording: {e}")

def setup_logging():
    """Setup logging with proper configuration"""
    # Create logs directory if it doesn't exist
    os.makedirs("logs", exist_ok=True)
    
    # Setup file handler with rotation
    log_filename = f"logs/twitch-recorder-{datetime.datetime.now().strftime('%Y%m%d')}.log"
    
    # Configure logging
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s - %(levelname)s - %(message)s',
        handlers=[
            logging.FileHandler(log_filename),
            logging.StreamHandler(sys.stdout)
        ]
    )

def main(argv):
    setup_logging()
    
    try:
        twitch_recorder = TwitchRecorder()
    except SystemExit:
        return
    except Exception as e:
        logging.error(f"Failed to initialize TwitchRecorder: {e}")
        return

    usage_message = "twitch-recorder.py -u <usernames> -q <quality>"

    try:
        opts, args = getopt.getopt(argv, "hu:q:l:", ["usernames=", "quality=", "log=", "logging=", "disable-ffmpeg"])
    except getopt.GetoptError:
        print(usage_message)
        sys.exit(2)
        
    for opt, arg in opts:
        if opt == "-h":
            print(usage_message)
            sys.exit()
        elif opt in ("-u", "--usernames"):
            twitch_recorder.usernames = [username.strip() for username in arg.split(",")]
            logging.info(f"Usernames set to: {twitch_recorder.usernames}")
        elif opt in ("-q", "--quality"):
            twitch_recorder.quality = arg
            logging.info(f"Quality set to: {arg}")
        elif opt in ("-l", "--log", "--logging"):
            logging_level = getattr(logging, arg.upper(), None)
            if not isinstance(logging_level, int):
                raise ValueError(f"Invalid log level: {arg.upper()}")
            logging.getLogger().setLevel(logging_level)
            logging.info(f"Logging level set to {arg.upper()}")
        elif opt == "--disable-ffmpeg":
            twitch_recorder.disable_ffmpeg = True
            logging.info("FFmpeg disabled")

    try:
        twitch_recorder.run()
    except KeyboardInterrupt:
        logging.info("Interrupted by user")
    except Exception as e:
        logging.error(f"Unexpected error: {e}")
    finally:
        logging.info("Application terminated")

if __name__ == "__main__":
    main(sys.argv[1:])
