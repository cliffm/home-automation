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
