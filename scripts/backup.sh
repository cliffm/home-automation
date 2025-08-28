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
