#!/usr/bin/env python3
"""
Docker Volume Configuration Sync Script
Syncs whitelisted configuration files from Docker volumes to git repository
For home-automation infrastructure management
"""

import os
import sys
import shutil
import subprocess
import json
import logging
from pathlib import Path
from datetime import datetime
from typing import Dict, List, Set
import argparse
import tomllib

# Configuration
DOCKER_VOLUME_PREFIX = "home-automation_"
CONFIG_BASE_PATH = "/home/cliffm/home-automation/configs"
GIT_REPO_PATH = "/home/cliffm/home-automation"
WHITELIST_CONFIG_FILE = "/home/cliffm/home-automation/scripts/whitelist.toml"

# Volume to directory mapping
VOLUME_MAPPINGS = {
    "home_assistant_config": "home-assistant",
    "node_red_data": "node-red", 
    "zwave_data": "zwave-js-ui"
}

class DockerVolumeSync:
    def __init__(self, dry_run: bool = False, verbose: bool = False, whitelist_file: str = None):
        self.dry_run = dry_run
        self.verbose = verbose
        self.whitelist_file = whitelist_file or WHITELIST_CONFIG_FILE
        self.whitelist_patterns = self.load_whitelist_config()
        self.setup_logging()
        
    def load_whitelist_config(self) -> Dict:
        """Load whitelist configuration from TOML file"""
        try:
            with open(self.whitelist_file, 'rb') as f:
                config = tomllib.load(f)
                return config.get('services', {})
        except FileNotFoundError:
            print(f"Warning: Whitelist file not found at {self.whitelist_file}")
            print("Creating default whitelist.toml file...")
            self.create_default_whitelist_file()
            # Load the newly created file
            with open(self.whitelist_file, 'rb') as f:
                config = tomllib.load(f)
                return config.get('services', {})
        except Exception as e:
            print(f"Error loading whitelist file {self.whitelist_file}: {e}")
            sys.exit(1)
    
    def create_default_whitelist_file(self):
        """Create a default whitelist.toml file with comprehensive patterns"""
        default_config = '''# Docker Volume Sync Whitelist Configuration
# This file controls which files are synced from Docker volumes to git repository

[services.home-assistant]
# Home Assistant configuration files
include = [
    "configuration.yaml",
    "automations.yaml", 
    "scripts.yaml",
    "scenes.yaml",
    "groups.yaml",
    "customize.yaml",
    "secrets.yaml.example",  # Template only, not actual secrets
    "ui-lovelace.yaml",
    "known_devices.yaml",
    "*.yaml",
    "*.yml",
    "blueprints/**/*.yaml",
    "custom_components/**/*.py",
    "custom_components/**/*.yaml",
    "custom_components/**/*.json",
    "custom_components/**/manifest.json",
    "themes/**/*.yaml",
    "packages/**/*.yaml",
    "integrations/**/*.yaml",
    ".storage/lovelace*",  # UI configuration
    ".storage/core.config_entries",
    ".storage/core.device_registry",
    ".storage/core.entity_registry",
    ".storage/auth_provider.homeassistant",
]

exclude = [
    "home-assistant.log*",
    "home-assistant_v2.db*", 
    ".storage/auth",
    ".storage/*token*",
    "secrets.yaml",  # Never sync actual secrets
    "*.db",
    "*.db-*",
    "*.sqlite*",
    "*.log*",
    "tts/**",
    "deps/**",
    "__pycache__/**",
    "*.pyc",
    ".cloud/**",
    ".google*",
    "*.pid",
    "*.json.backup",
    ".HA_VERSION",
    "OZW_Log.txt",
]

[services.node-red]
# Node-RED flows and configuration
include = [
    "flows.json",
    "flows_cred.json.example",  # Template only
    "settings.js",
    "package.json",
    "lib/**/*.js",
    "lib/**/*.json",
]

exclude = [
    "flows_cred.json",  # Never sync actual credentials
    ".config.*.json",
    ".sessions.json",
    "node_modules/**",
    ".npm/**",
    "*.log",
    ".node-red-contrib-*/**",  # Downloaded modules
]

[services.zwave-js-ui]
# ZWave-JS-UI configuration and data
include = [
    "settings.json",
    "scenes.jsonl",
    "mqtt.json",
    "store.json",
    "nodes.json",
]

exclude = [
    "zwave-js-ui.log*",
    "*.cache",
    "cache/**",
    "sessions/**",
    "*.tmp",
    "zwavejs_*.json",  # Network cache files
]
'''
        
        # Ensure the scripts directory exists
        os.makedirs(os.path.dirname(self.whitelist_file), exist_ok=True)
        
        with open(self.whitelist_file, 'w') as f:
            f.write(default_config)
        
        print(f"Created default whitelist configuration at {self.whitelist_file}")
        print("You can now edit this file to customize the sync patterns.")
        
    def setup_logging(self):
        """Setup logging configuration"""
        # Create logs directory if it doesn't exist
        logs_dir = f'{GIT_REPO_PATH}/logs'
        os.makedirs(logs_dir, exist_ok=True)
        
        level = logging.DEBUG if self.verbose else logging.INFO
        logging.basicConfig(
            level=level,
            format='%(asctime)s - %(levelname)s - %(message)s',
            handlers=[
                logging.StreamHandler(sys.stdout),
                logging.FileHandler(f'{logs_dir}/volume_sync.log', 'a')
            ]
        )
        self.logger = logging.getLogger(__name__)
    
    def get_docker_volume_path(self, volume_name: str) -> str:
        """Get the actual filesystem path of a Docker volume"""
        try:
            cmd = f"docker volume inspect {DOCKER_VOLUME_PREFIX}{volume_name}"
            result = subprocess.run(cmd.split(), capture_output=True, text=True, check=True)
            volume_info = json.loads(result.stdout)
            return volume_info[0]['Mountpoint']
        except (subprocess.CalledProcessError, json.JSONDecodeError, IndexError, KeyError) as e:
            self.logger.error(f"Failed to get volume path for {volume_name}: {e}")
            return None
    
    def should_include_file(self, file_path: Path, service: str, volume_root: Path) -> bool:
        """Check if a file should be included based on whitelist patterns"""
        relative_path = file_path.relative_to(volume_root)
        relative_str = str(relative_path)
        
        patterns = self.whitelist_patterns.get(service, {})
        include_patterns = patterns.get("include", [])
        exclude_patterns = patterns.get("exclude", [])
        
        # Check exclude patterns first (they take precedence)
        for pattern in exclude_patterns:
            if self.matches_pattern(relative_str, pattern):
                self.logger.debug(f"Excluding {relative_str} (matches exclude pattern: {pattern})")
                return False
        
        # Check include patterns
        for pattern in include_patterns:
            if self.matches_pattern(relative_str, pattern):
                self.logger.debug(f"Including {relative_str} (matches include pattern: {pattern})")
                return True
        
        self.logger.debug(f"Excluding {relative_str} (no include pattern match)")
        return False
    
    def matches_pattern(self, file_path: str, pattern: str) -> bool:
        """Check if a file path matches a pattern (supports basic wildcards)"""
        import fnmatch
        return fnmatch.fnmatch(file_path, pattern)
    
    def sync_volume_to_config(self, volume_name: str, target_dir: str) -> bool:
        """Sync a single Docker volume to config directory"""
        self.logger.info(f"Syncing volume {volume_name} to {target_dir}")
        
        # Get volume source path
        volume_path = self.get_docker_volume_path(volume_name)
        if not volume_path:
            return False
        
        volume_root = Path(volume_path)
        target_root = Path(CONFIG_BASE_PATH) / target_dir
        
        if not volume_root.exists():
            self.logger.error(f"Volume path does not exist: {volume_root}")
            return False
        
        # Create target directory
        if not self.dry_run:
            target_root.mkdir(parents=True, exist_ok=True)
        
        # Track synced files
        synced_files = []
        skipped_files = []
        
        # Walk through all files in volume
        for file_path in volume_root.rglob("*"):
            if file_path.is_file():
                if self.should_include_file(file_path, target_dir, volume_root):
                    # Calculate target path
                    relative_path = file_path.relative_to(volume_root)
                    target_path = target_root / relative_path
                    
                    # Create parent directories
                    if not self.dry_run:
                        target_path.parent.mkdir(parents=True, exist_ok=True)
                        
                        # Copy file if it's different
                        if not target_path.exists() or not self.files_identical(file_path, target_path):
                            shutil.copy2(file_path, target_path)
                            self.logger.info(f"Copied: {relative_path}")
                        else:
                            self.logger.debug(f"Unchanged: {relative_path}")
                    else:
                        self.logger.info(f"Would copy: {relative_path}")
                    
                    synced_files.append(str(relative_path))
                else:
                    skipped_files.append(str(file_path.relative_to(volume_root)))
        
        self.logger.info(f"Volume {volume_name}: {len(synced_files)} files synced, {len(skipped_files)} files skipped")
        return True
    
    def files_identical(self, file1: Path, file2: Path) -> bool:
        """Check if two files are identical"""
        try:
            return file1.stat().st_mtime == file2.stat().st_mtime and file1.stat().st_size == file2.stat().st_size
        except OSError:
            return False
    
    def clean_orphaned_files(self, target_dir: str) -> None:
        """Remove files in config that no longer exist in volume (with whitelist check)"""
        self.logger.info(f"Cleaning orphaned files in {target_dir}")
        
        volume_name = None
        for vol, tdir in VOLUME_MAPPINGS.items():
            if tdir == target_dir:
                volume_name = vol
                break
        
        if not volume_name:
            return
        
        volume_path = self.get_docker_volume_path(volume_name)
        if not volume_path:
            return
        
        volume_root = Path(volume_path)
        target_root = Path(CONFIG_BASE_PATH) / target_dir
        
        if not target_root.exists():
            return
        
        # Get list of files that should exist based on volume + whitelist
        should_exist = set()
        for file_path in volume_root.rglob("*"):
            if file_path.is_file() and self.should_include_file(file_path, target_dir, volume_root):
                relative_path = file_path.relative_to(volume_root)
                should_exist.add(relative_path)
        
        # Find files in target that shouldn't exist
        removed_count = 0
        for file_path in target_root.rglob("*"):
            if file_path.is_file():
                relative_path = file_path.relative_to(target_root)
                if relative_path not in should_exist:
                    if not self.dry_run:
                        file_path.unlink()
                        self.logger.info(f"Removed orphaned file: {relative_path}")
                    else:
                        self.logger.info(f"Would remove orphaned file: {relative_path}")
                    removed_count += 1
        
        if removed_count == 0:
            self.logger.info(f"No orphaned files found in {target_dir}")
        else:
            self.logger.info(f"Removed {removed_count} orphaned files from {target_dir}")
    
    def git_status(self) -> bool:
        """Check git status and show changes"""
        try:
            os.chdir(GIT_REPO_PATH)
            result = subprocess.run(["git", "status", "--porcelain"], capture_output=True, text=True, check=True)
            
            if result.stdout.strip():
                self.logger.info("Git changes detected:")
                for line in result.stdout.strip().split('\n'):
                    self.logger.info(f"  {line}")
                return True
            else:
                self.logger.info("No git changes detected")
                return False
        except subprocess.CalledProcessError as e:
            self.logger.error(f"Git status check failed: {e}")
            return False
    
    def git_add_and_commit(self, message: str = None) -> bool:
        """Add changes to git and commit"""
        if self.dry_run:
            self.logger.info("Dry run: Would add and commit changes to git")
            return True
        
        try:
            os.chdir(GIT_REPO_PATH)
            
            # Add config files
            subprocess.run(["git", "add", "configs/"], check=True)
            
            # Check if there are changes to commit
            result = subprocess.run(["git", "status", "--porcelain"], capture_output=True, text=True, check=True)
            if not result.stdout.strip():
                self.logger.info("No changes to commit")
                return True
            
            # Commit changes
            if not message:
                timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
                message = f"Auto-sync config changes - {timestamp}"
            
            subprocess.run(["git", "commit", "-m", message], check=True)
            self.logger.info(f"Changes committed: {message}")
            return True
            
        except subprocess.CalledProcessError as e:
            self.logger.error(f"Git commit failed: {e}")
            return False
    
    def sync_all_volumes(self, auto_commit: bool = False) -> bool:
        """Sync all configured volumes"""
        self.logger.info("Starting Docker volume sync")
        success_count = 0
        
        for volume_name, target_dir in VOLUME_MAPPINGS.items():
            if self.sync_volume_to_config(volume_name, target_dir):
                success_count += 1
                if not self.dry_run:
                    self.clean_orphaned_files(target_dir)
        
        self.logger.info(f"Sync completed: {success_count}/{len(VOLUME_MAPPINGS)} volumes synced successfully")
        
        # Check git status
        if self.git_status() and auto_commit:
            self.git_add_and_commit()
        
        return success_count == len(VOLUME_MAPPINGS)
    
    def show_whitelist_summary(self):
        """Display whitelist configuration summary"""
        print(f"\n=== WHITELIST CONFIGURATION SUMMARY ===")
        print(f"Configuration file: {self.whitelist_file}")
        
        if not self.whitelist_patterns:
            print("No whitelist patterns loaded!")
            return
            
        for service, patterns in self.whitelist_patterns.items():
            print(f"\n{service.upper()}:")
            print(f"  Include patterns ({len(patterns.get('include', []))}):")
            for pattern in patterns.get('include', []):
                print(f"    + {pattern}")
            print(f"  Exclude patterns ({len(patterns.get('exclude', []))}):")
            for pattern in patterns.get('exclude', []):
                print(f"    - {pattern}")

def main():
    parser = argparse.ArgumentParser(description="Sync Docker volume configurations to git repository")
    parser.add_argument("--dry-run", action="store_true", help="Show what would be synced without making changes")
    parser.add_argument("--verbose", "-v", action="store_true", help="Enable verbose logging")
    parser.add_argument("--auto-commit", action="store_true", help="Automatically commit changes to git")
    parser.add_argument("--show-whitelist", action="store_true", help="Display whitelist configuration and exit")
    parser.add_argument("--volume", help="Sync only specified volume (e.g., home_assistant_config)")
    parser.add_argument("--whitelist-file", help=f"Path to whitelist TOML file (default: {WHITELIST_CONFIG_FILE})")
    
    args = parser.parse_args()
    
    syncer = DockerVolumeSync(dry_run=args.dry_run, verbose=args.verbose, whitelist_file=args.whitelist_file)
    
    if args.show_whitelist:
        syncer.show_whitelist_summary()
        return
    
    if args.volume:
        # Sync single volume
        if args.volume in VOLUME_MAPPINGS:
            target_dir = VOLUME_MAPPINGS[args.volume]
            success = syncer.sync_volume_to_config(args.volume, target_dir)
            if success and not args.dry_run:
                syncer.clean_orphaned_files(target_dir)
            if success and syncer.git_status() and args.auto_commit:
                syncer.git_add_and_commit(f"Sync {args.volume} configuration")
        else:
            print(f"Unknown volume: {args.volume}")
            print(f"Available volumes: {', '.join(VOLUME_MAPPINGS.keys())}")
            sys.exit(1)
    else:
        # Sync all volumes
        syncer.sync_all_volumes(auto_commit=args.auto_commit)

if __name__ == "__main__":
    main()
