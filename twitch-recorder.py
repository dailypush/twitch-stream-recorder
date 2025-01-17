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
from tqdm import tqdm
from pathlib import Path
from colorama import init, Fore, Style

init(autoreset=True)  # Autoreset will automatically reset the style after each print statement

class TwitchResponseStatus(enum.Enum):
    ONLINE = 0
    OFFLINE = 1
    NOT_FOUND = 2
    UNAUTHORIZED = 3
    ERROR = 4

class TwitchRecorder:
    def __init__(self):
        # Load configuration from config.json
        with open("config.json", "r") as config_file:
            config_data = json.load(config_file)

        # Global configuration
        self.ffmpeg_path = config_data["ffmpeg_path"]
        self.disable_ffmpeg = config_data["disable_ffmpeg"]
        self.refresh = config_data["refresh_interval"]
        self.root_path = config_data["root_path"]
        self.max_concurrent_recordings = config_data.get("max_concurrent_recordings", 2)
        self.active_recordings = 0

        # User configuration
        self.prune_after_days = config_data["prune_after_days"]
        self.upload_to_network_drive_enabled = config_data["upload_to_network_drive"]
        self.network_drive_path = config_data["network_drive_path"]
        self.usernames = config_data["usernames"]
        self.quality = config_data["stream_quality"]

        # Twitch configuration
        self.client_id = config_data["client_id"]
        self.client_secret = config_data["client_secret"]
        self.token_url = f"https://id.twitch.tv/oauth2/token?client_id={self.client_id}&client_secret={self.client_secret}&grant_type=client_credentials"
        self.url = "https://api.twitch.tv/helix/streams"
        self.access_token = self.fetch_access_token()

    def can_start_new_recording(self):
        if self.active_recordings >= self.max_concurrent_recordings:
            return False
        cpu_usage = psutil.cpu_percent()
        memory_usage = psutil.virtual_memory().percent
        if cpu_usage > 80 or memory_usage > 80:  # Adjust these thresholds as needed
            return False
        return True

    def fetch_access_token(self):
        token_response = requests.post(self.token_url, timeout=15)
        token_response.raise_for_status()
        token = token_response.json()
        return token["access_token"]

    def run(self):
        paths = self.create_directories()
        while True:
            if psutil.cpu_percent() < 50:  # Avoid starting new checks if CPU usage is high
                for username in self.usernames:
                    recorded_path, processed_path = paths[username]
                    self.process_previous_recordings(recorded_path, processed_path)
                    logging.info(f"checking for {username} every {self.refresh} seconds, recording with {self.quality} quality")
                    self.loop_check(username, recorded_path, processed_path)
            else:
                logging.warning("High CPU usage detected. Pausing new checks temporarily.")
            time.sleep(self.refresh)
        
    def create_directories(self):
        paths = {}
        for username in self.usernames:
            recorded_path = os.path.join(self.root_path, "recorded", username)
            processed_path = os.path.join(self.root_path, "processed", username)
            os.makedirs(recorded_path, exist_ok=True)
            os.makedirs(processed_path, exist_ok=True)
            paths[username] = (recorded_path, processed_path)
        return paths

    def prune_old_files(self, path):
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
                        logging.error(f"Failed to delete old file: {e}")

    def process_previous_recordings(self, recorded_path, processed_path):
        video_list = [f for f in os.listdir(recorded_path) if os.path.isfile(os.path.join(recorded_path, f))]
        if video_list:
            logging.info("processing previously recorded files")
        for f in video_list:
            recorded_filename = os.path.join(recorded_path, f)
            processed_filename = os.path.join(processed_path, f)
            self.process_recorded_file(recorded_filename, processed_filename)

    def process_recorded_file(self, recorded_filename, processed_filename):
        if self.disable_ffmpeg:
            logging.info(f"moving: {recorded_filename}")
            shutil.move(recorded_filename, processed_filename)
        else:
            logging.info(f"fixing {recorded_filename}")
            self.ffmpeg_copy_and_fix_errors(recorded_filename, processed_filename)
        if self.upload_to_network_drive_enabled:
            self.upload_to_network_drive(processed_filename)

    def ffmpeg_copy_and_fix_errors(self, recorded_filename, processed_filename):
        try:
                # Limiting resource usage of subprocess
            subprocess.call([self.ffmpeg_path, "-err_detect", "ignore_err", "-i", recorded_filename, "-c", "copy", processed_filename],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            os.remove(recorded_filename)
        except Exception as e:
            logging.error(f"Error processing file with ffmpeg: {e}")

    def check_user(self, username):
        headers = {"Client-ID": self.client_id, "Authorization": f"Bearer {self.access_token}"}
        try:
            r = requests.get(f"{self.url}?user_login={username}", headers=headers, timeout=15)
            r.raise_for_status()
            info = r.json()
            return TwitchResponseStatus.ONLINE if info["data"] else TwitchResponseStatus.OFFLINE, info
        except requests.exceptions.RequestException as e:
            logging.error(f"Error checking user {username}: {e}")
            if e.response:
                if e.response.status_code == 401:
                    return TwitchResponseStatus.UNAUTHORIZED, None
                if e.response.status_code == 404:
                    return TwitchResponseStatus.NOT_FOUND, None
            return TwitchResponseStatus.ERROR, None

    def upload_to_network_drive(self, processed_filename):
        try:
            filename = os.path.basename(processed_filename)
            destination = os.path.join(self.network_drive_path, filename)
            shutil.copy(processed_filename, destination)
            logging.info(f"File uploaded to network drive: {destination}")
        except Exception as e:
            logging.error(f"Failed to upload file to network drive: {e}")

    def update_progress_bar(self, bar, recorded_filename):
        if os.path.exists(recorded_filename):
            current_size = os.path.getsize(recorded_filename)
            bar.total = current_size  # Set the total size to the current size of the file
            bar.n = current_size  # Set the current progress to the file size
            bar.refresh()  # Refresh the progress bar display

    def loop_check(self, username, recorded_path, processed_path):
        try:
            status, info = self.check_user(username)
            if status == TwitchResponseStatus.NOT_FOUND:
                logging.error(f"{Fore.RED}username {username} not found, invalid username or typo")
            elif status == TwitchResponseStatus.OFFLINE:
                logging.info(f"{Fore.YELLOW}{username} currently offline")
            elif status == TwitchResponseStatus.UNAUTHORIZED:
                logging.info(f"{Fore.RED}unauthorized, refreshing access token")
                self.access_token = self.fetch_access_token()
            elif status == TwitchResponseStatus.ONLINE:
                if self.can_start_new_recording():
                    logging.info(f"{Fore.GREEN}{username} online, starting recording")
                    self.active_recordings += 1
                    channel = info["data"][0]
                    filename = f"{username} - {datetime.datetime.now().strftime('%Y-%m-%d %Hh%Mm%Ss')} - {channel.get('title')}.mp4"
                    filename = "".join(x for x in filename if x.isalnum() or x in [" ", "-", "_", "."])
                    recorded_filename = os.path.join(recorded_path, filename)
                    processed_filename = os.path.join(processed_path, filename)

                    # Start streamlink process
                    streamlink_process = subprocess.Popen(
                        ["streamlink", "--twitch-disable-ads", f"twitch.tv/{username}", self.quality, "-o", recorded_filename],
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE
                    )
                    # Check for errors
                    if streamlink_process.stderr:
                        logging.error(f"Streamlink error: {streamlink_process.stderr.read().decode('utf-8')}")
                    
                    with tqdm(total=1, unit='B', unit_scale=True, desc=filename, ncols=None) as bar:
                        while streamlink_process.poll() is None:
                            time.sleep(5)  # Update frequency
                            self.update_progress_bar(bar, recorded_filename)

                        self.update_progress_bar(bar, recorded_filename)  # Final update after recording stops


                    logging.info("Recording stream is done, processing video file")
                    if os.path.exists(recorded_filename):
                        self.process_recorded_file(recorded_filename, processed_filename)
                    else:
                        logging.info("Skip fixing, file not found")
                    logging.info("Processing is done")
                    self.active_recordings -= 1
                else:
                    logging.info(f"{Fore.YELLOW}Skipping recording for {username} due to high resource usage.")
        except Exception as e:
            logging.error(f"{Fore.RED}Unexpected error while checking or recording {username}: {e}")
            self.active_recordings = max(0, self.active_recordings - 1)
            time.sleep(300)

def main(argv):
    twitch_recorder = TwitchRecorder()
    usage_message = "twitch-recorder.py -u <usernames> -q <quality>"
    logging.basicConfig(filename="twitch-recorder.log", level=logging.INFO)
    logging.getLogger().addHandler(logging.StreamHandler())

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
            print("Usernames:", twitch_recorder.usernames)
        elif opt in ("-q", "--quality"):
            twitch_recorder.quality = arg
        elif opt in ("-l", "--log", "--logging"):
            logging_level = getattr(logging, arg.upper(), None)
            if not isinstance(logging_level, int):
                raise ValueError(f"invalid log level: {arg.upper()}")
            logging.basicConfig(level=logging_level)
            logging.info(f"logging configured to {arg.upper()}")
        elif opt == "--disable-ffmpeg":
            twitch_recorder.disable_ffmpeg = True
            logging.info("ffmpeg disabled")

    twitch_recorder.run()


if __name__ == "__main__":
    main(sys.argv[1:])
