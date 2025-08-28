#!/bin/bash

# Home Automation Repository Structure Creator
# Creates a complete directory structure for home automation Git repository

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${BLUE}$1${NC}"
}

# Get repository name and location
REPO_NAME=${1:-"home-automation"}
REPO_PATH=$(pwd)/$REPO_NAME

print_header "🏠 Creating Home Automation Repository Structure"
echo "Repository: $REPO_PATH"
echo

# Check if directory already exists
if [ -d "$REPO_PATH" ]; then
    print_warning "Directory $REPO_PATH already exists!"
    read -p "Do you want to continue and add missing directories? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_error "Aborted by user"
        exit 1
    fi
fi

# Create main repository directory
mkdir -p "$REPO_PATH"
cd "$REPO_PATH"

print_status "Creating directory structure..."

# Create main directories
mkdir -p docs/services
mkdir -p stacks/{home-automation,frigate,watchtower,monitoring,networking}
mkdir -p configs/{home-assistant,node-red,frigate,mqtt,nginx,grafana}
mkdir -p configs/home-assistant/{packages,custom_components}
mkdir -p configs/node-red/lib/flows
mkdir -p configs/frigate/models
mkdir -p configs/nginx/{sites-available,ssl}
mkdir -p configs/grafana/{dashboards,provisioning/datasources,provisioning/dashboards}
mkdir -p scripts/migration
mkdir -p backups
mkdir -p templates/service-configs

print_status "Creating placeholder files..."

# Create .gitkeep files for empty directories
touch configs/home-assistant/custom_components/.gitkeep
touch configs/frigate/models/.gitkeep
touch configs/nginx/ssl/.gitkeep
touch backups/.gitkeep

# Create main README.md
cat > README.md << 'EOF'
# Home Automation Stack

This repository contains Docker Compose stacks and configurations for my home automation setup.

## 🏗️ Architecture

- **Home Assistant**: Central home automation platform
- **Node-RED**: Visual automation flows
- **Frigate**: AI-powered NVR with object detection
- **MQTT**: Message broker for IoT devices
- **Watchtower**: Automated container updates

## 🚀 Quick Start

1. Clone this repository
2. Copy `.env.example` files to `.env` and configure
3. Deploy stacks using Portainer or Docker Compose

## 📁 Repository Structure

- `stacks/`: Docker Compose files for each service stack
- `configs/`: Configuration files for all services
- `scripts/`: Automation and deployment scripts
- `docs/`: Documentation and setup guides

## 🔧 Deployment

### Using Docker Compose
```bash
cd stacks/home-automation
cp .env.example .env
# Edit .env with your settings
docker compose up -d
```

### Using Portainer
Configure Git integration to pull from this repository's `stacks/` directory.

## 📚 Documentation

See the `docs/` directory for detailed setup and configuration guides.
EOF

# Create main .gitignore
cat > .gitignore << 'EOF'
# Secrets and credentials
.env
*.env
!*.env.example
secrets.yaml
*_cred.json
*.passwd
*.key
*.pem
*.crt

# Logs and temporary files
*.log
*.tmp
.DS_Store
Thumbs.db

# Backup files
*.backup
*.bak
*.old

# Runtime data
data/
logs/
*.db
*.sqlite

# IDE and editor files
.vscode/
.idea/
*.swp
*.swo
*~

# OS generated files
.DS_Store
.DS_Store?
._*
.Spotlight-V100
.Trashes
ehthumbs.db
Thumbs.db
EOF

print_status "Creating stack templates..."

# Create home-automation stack template
cat > stacks/home-automation/docker-compose.yml << 'EOF'
services:
  homeassistant:
    container_name: home-assistant
    image: ghcr.io/home-assistant/home-assistant:2025.8.2
    privileged: true
    restart: unless-stopped
    volumes:
      - home_assistant_config:/config
      - /etc/localtime:/etc/localtime:ro
      - /run/dbus:/run/dbus:ro
    networks:
      - home_automation
    ports:
      - "8123:8123"
    environment:
      - TZ=${TIMEZONE}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8123/manifest.json"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    labels:
      - "com.centurylinklabs.watchtower.enable=true"

  node-red:
    container_name: node-red
    image: nodered/node-red:4.1.0
    restart: unless-stopped
    volumes:
      - node_red_data:/data
      - /etc/localtime:/etc/localtime:ro
    networks:
      - home_automation
    ports:
      - "1880:1880"
    environment:
      - TZ=${TIMEZONE}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:1880/"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 3m
    labels:
      - "com.centurylinklabs.watchtower.enable=true"

  mqtt:
    container_name: mosquitto
    image: eclipse-mosquitto:2.0.22
    restart: unless-stopped
    volumes:
      - mosquitto_config:/mosquitto/config
      - mosquitto_data:/mosquitto/data
      - mosquitto_logs:/mosquitto/log
      - ./configs/mosquitto.conf:/mosquitto/config/mosquitto.conf:ro
    networks:
      - home_automation
    ports:
      - "1883:1883"
      - "9001:9001"
    environment:
      - TZ=${TIMEZONE}
    healthcheck:
      test: ["CMD-SHELL", "mosquitto_pub -h 127.0.0.1 -p 1883 -t 'healthcheck' -m 'test' -q 0 -u ${MQTT_USER} -P ${MQTT_PASS} || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    labels:
      - "com.centurylinklabs.watchtower.enable=true"

networks:
  home_automation:
    driver: bridge

volumes:
  home_assistant_config:
  node_red_data:
  mosquitto_config:
  mosquitto_data:
  mosquitto_logs:
EOF

# Create .env.example for home-automation stack
cat > stacks/home-automation/.env.example << 'EOF'
# Timezone
TIMEZONE=America/New_York

# MQTT Configuration
MQTT_USER=your_mqtt_username
MQTT_PASS=your_mqtt_password

# Network Configuration
# SUBNET=172.20.0.0/16
EOF

# Create README for home-automation stack
cat > stacks/home-automation/README.md << 'EOF'
# Home Automation Stack

Core home automation services including Home Assistant, Node-RED, and MQTT.

## Services

- **Home Assistant** (Port 8123): Central automation platform
- **Node-RED** (Port 1880): Visual automation flows
- **Mosquitto MQTT** (Ports 1883, 9001): Message broker

## Setup

1. Copy `.env.example` to `.env`
2. Configure your settings in `.env`
3. Deploy: `docker compose up -d`

## Configuration

Service configurations are stored in the `../../configs/` directory and mounted into containers.
EOF

# Create Frigate stack template
cat > stacks/frigate/docker-compose.yml << 'EOF'
services:
  frigate:
    container_name: frigate
    image: ghcr.io/blakeblackshear/frigate:stable
    restart: unless-stopped
    shm_size: "256mb"
    devices:
      - /dev/bus/usb:/dev/bus/usb  # Coral USB accelerator
    volumes:
      - frigate_config:/config
      - frigate_media:/media/frigate
      - type: tmpfs
        target: /tmp/cache
        tmpfs:
          size: 1000000000  # 1GB
    ports:
      - "5000:5000"
      - "8554:8554"  # RTSP feeds
      - "8555:8555/tcp"  # WebRTC over tcp
      - "8555:8555/udp"  # WebRTC over udp
    environment:
      - FRIGATE_RTSP_PASSWORD=${FRIGATE_RTSP_PASSWORD}
      - TZ=${TIMEZONE}
    labels:
      - "com.centurylinklabs.watchtower.enable=true"

  go2rtc:
    container_name: go2rtc
    image: alexxit/go2rtc:latest
    restart: unless-stopped
    volumes:
      - go2rtc_config:/config
    ports:
      - "1984:1984"
    labels:
      - "com.centurylinklabs.watchtower.enable=true"

volumes:
  frigate_config:
  frigate_media:
  go2rtc_config:
EOF

# Create .env.example for frigate stack
cat > stacks/frigate/.env.example << 'EOF'
# Timezone
TIMEZONE=America/New_York

# Frigate Configuration
FRIGATE_RTSP_PASSWORD=your_rtsp_password

# Camera Configuration
# Add your camera URLs and credentials here
EOF

# Create README for frigate stack
cat > stacks/frigate/README.md << 'EOF'
# Frigate NVR Stack

AI-powered Network Video Recorder with object detection.

## Services

- **Frigate** (Port 5000): NVR with AI object detection
- **go2rtc** (Port 1984): Real-time streaming server

## Setup

1. Copy `.env.example` to `.env`
2. Configure cameras in `../../configs/frigate/config.yml`
3. Deploy: `docker compose up -d`

## Hardware Acceleration

This stack is configured for Coral USB accelerator. Modify device mounts as needed for your hardware.
EOF

# Create Watchtower stack
cat > stacks/watchtower/docker-compose.yml << 'EOF'
services:
  watchtower:
    container_name: watchtower
    image: containrrr/watchtower:latest
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /etc/localtime:/etc/localtime:ro
    environment:
      - TZ=${TIMEZONE}
      - WATCHTOWER_LABEL_ENABLE=true
      - WATCHTOWER_SCHEDULE=0 0 3 * * *
      - WATCHTOWER_NOTIFICATIONS=${WATCHTOWER_NOTIFICATIONS}
      - WATCHTOWER_NOTIFICATION_EMAIL_FROM=${WATCHTOWER_EMAIL}
      - WATCHTOWER_NOTIFICATION_EMAIL_TO=${WATCHTOWER_EMAIL}
      - WATCHTOWER_NOTIFICATION_EMAIL_SERVER=smtp.gmail.com
      - WATCHTOWER_NOTIFICATION_EMAIL_SERVER_PORT=587
      - WATCHTOWER_NOTIFICATION_EMAIL_SERVER_USER=${WATCHTOWER_EMAIL}
      - WATCHTOWER_NOTIFICATION_EMAIL_SERVER_PASSWORD=${WATCHTOWER_EMAIL_PASSWORD}
      - WATCHTOWER_MONITOR_ONLY=false
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_INCLUDE_STOPPED=false
      - WATCHTOWER_REVIVE_STOPPED=false
      - WATCHTOWER_LOG_LEVEL=info
      - WATCHTOWER_ROLLING_RESTART=true
    healthcheck:
      test: ["CMD", "/watchtower", "--help"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s
    labels:
      - "com.centurylinklabs.watchtower.enable=false"
EOF

# Create .env.example for watchtower
cat > stacks/watchtower/.env.example << 'EOF'
# Timezone
TIMEZONE=America/New_York

# Email Notifications (optional)
WATCHTOWER_NOTIFICATIONS=email
WATCHTOWER_EMAIL=your-email@gmail.com
WATCHTOWER_EMAIL_PASSWORD=your-gmail-app-password
EOF

print_status "Creating documentation templates..."

# Create setup documentation
cat > docs/setup.md << 'EOF'
# Setup Guide

## Prerequisites

- Docker and Docker Compose v2.x
- Git
- (Optional) Portainer for web-based management

## Initial Setup

1. Clone this repository
2. Copy environment files
3. Configure services
4. Deploy stacks

## Environment Configuration

Each stack has an `.env.example` file. Copy these to `.env` and configure:

```bash
cd stacks/home-automation
cp .env.example .env
# Edit .env with your settings
```

## Service Configuration

Configuration files are stored in the `configs/` directory. Customize these before deployment.

## Deployment Options

### Docker Compose
```bash
cd stacks/home-automation
docker compose up -d
```

### Portainer
Configure Git integration pointing to this repository.
EOF

# Create basic scripts
cat > scripts/deploy.sh << 'EOF'
#!/bin/bash

# Deploy all stacks
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

echo "Deploying home automation stacks..."

for stack in "$REPO_ROOT"/stacks/*/; do
    if [ -f "$stack/docker-compose.yml" ]; then
        stack_name=$(basename "$stack")
        echo "Deploying $stack_name..."
        cd "$stack"
        if [ -f ".env" ]; then
            docker compose up -d
        else
            echo "Warning: No .env file found for $stack_name"
        fi
    fi
done

echo "Deployment complete!"
EOF

chmod +x scripts/deploy.sh

cat > scripts/backup.sh << 'EOF'
#!/bin/bash

# Backup home automation data
BACKUP_DIR="./backups/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

echo "Creating backup in $BACKUP_DIR..."

# Backup Docker volumes
docker run --rm -v home_assistant_config:/source:ro -v "$(pwd)/$BACKUP_DIR":/backup alpine tar czf /backup/home_assistant_config.tar.gz -C /source .
docker run --rm -v node_red_data:/source:ro -v "$(pwd)/$BACKUP_DIR":/backup alpine tar czf /backup/node_red_data.tar.gz -C /source .
docker run --rm -v mosquitto_data:/source:ro -v "$(pwd)/$BACKUP_DIR":/backup alpine tar czf /backup/mosquitto_data.tar.gz -C /source .

# Backup configs
tar czf "$BACKUP_DIR/configs.tar.gz" configs/

echo "Backup complete: $BACKUP_DIR"
EOF

chmod +x scripts/backup.sh

print_status "Creating basic configuration templates..."

# Create basic mosquitto config
cat > configs/mqtt/mosquitto.conf << 'EOF'
# Mosquitto Configuration
persistence true
persistence_location /mosquitto/data/

# Networking
listener 1883 0.0.0.0
protocol mqtt

listener 9001 0.0.0.0
protocol websockets

# Authentication
allow_anonymous false
password_file /mosquitto/config/mosquitto.passwd

# Logging
log_dest file /mosquitto/log/mosquitto.log
log_type error
log_type warning
log_type notice
log_type information
EOF

# Create mosquitto password file example
cat > configs/mqtt/mosquitto.passwd.example << 'EOF'
# Mosquitto password file
# Generate with: mosquitto_passwd -c mosquitto.passwd username
# username:$7$101$password_hash_here
EOF

# Create basic Home Assistant configuration
cat > configs/home-assistant/configuration.yaml << 'EOF'
# Home Assistant Configuration
default_config:

# Load additional configuration from packages
homeassistant:
  packages: !include_dir_named packages
  customize: !include customize.yaml

# MQTT Configuration
mqtt:
  broker: mosquitto
  port: 1883
  username: !secret mqtt_username
  password: !secret mqtt_password

# Node-RED Integration
# Configure via UI after setup

# Frigate Integration (if using)
# frigate:
#   host: frigate
#   port: 5000
EOF

cat > configs/home-assistant/secrets.yaml.example << 'EOF'
# Home Assistant Secrets
# Copy this file to secrets.yaml and configure

# MQTT
mqtt_username: your_mqtt_username
mqtt_password: your_mqtt_password

# API Keys
weather_api_key: your_weather_api_key

# Device Credentials
router_username: your_router_username
router_password: your_router_password
EOF

# Create basic Frigate config
cat > configs/frigate/config.yml << 'EOF'
# Frigate Configuration
mqtt:
  host: mosquitto
  port: 1883
  user: "{FRIGATE_MQTT_USER}"
  password: "{FRIGATE_MQTT_PASSWORD}"

go2rtc:
  streams:
    # Define your camera streams here
    # camera_name: "rtsp://username:password@camera_ip/stream"

cameras:
  # Configure your cameras here
  # camera_name:
  #   ffmpeg:
  #     inputs:
  #       - path: rtsp://username:password@camera_ip/stream
  #         roles:
  #           - detect
  #           - record
  #   detect:
  #     width: 1920
  #     height: 1080
  #   record:
  #     enabled: true
  #   snapshots:
  #     enabled: true

detectors:
  cpu1:
    type: cpu
    num_threads: 3

# Objects to detect
objects:
  track:
    - person
    - car
    - bicycle
    - motorcycle
    - cat
    - dog
EOF

print_header "✅ Repository structure created successfully!"
echo
print_status "Repository location: $REPO_PATH"
print_status "Next steps:"
echo "  1. cd $REPO_NAME"
echo "  2. Initialize git: git init"
echo "  3. Copy your existing configurations to the configs/ directory"
echo "  4. Configure .env files from .env.example templates"
echo "  5. Test deployment: cd stacks/home-automation && docker compose up -d"
echo
print_warning "Remember to:"
echo "  - Never commit .env files (they're in .gitignore)"
echo "  - Configure secrets.yaml files for each service"
echo "  - Test each stack individually before deploying all"
echo
print_status "Happy automating! 🏠🤖"


