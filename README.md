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
