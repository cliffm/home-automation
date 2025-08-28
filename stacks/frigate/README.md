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
