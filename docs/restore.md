# Quick Restore Cheat Sheet

## 🚨 Emergency Volume Restore

### Restore Single Volume (Example: Home Assistant)

```bash
# 1. Stop the service
cd ~/home-automation/stacks/home-automation
docker compose stop home-assistant

# 2. Find latest backup
LATEST_BACKUP=$(ls -t /home/cliffm/backups/daily/ | head -1)
echo "Using backup: $LATEST_BACKUP"

# 3. Restore the volume
docker run --rm \
    -v home-automation_home_assistant_config:/target \
    -v "/home/cliffm/backups/daily/$LATEST_BACKUP/volumes:/backup:ro" \
    alpine sh -c "rm -rf /target/* /target/.* 2>/dev/null || true; tar xzf /backup/home-automation_home_assistant_config.tar.gz -C /target"

# 4. Restart service
docker compose start home-assistant
```

### Restore All Volumes (Disaster Recovery)

```bash
#!/bin/bash
# Full restore script - save as /usr/local/bin/restore-backup.sh

BACKUP_DATE="$1"
if [ -z "$BACKUP_DATE" ]; then
    echo "Usage: $0 <backup_date>"
    echo "Available backups:"
    ls /home/cliffm/backups/daily/
    exit 1
fi

BACKUP_DIR="/home/cliffm/backups/daily/$BACKUP_DATE/volumes"

if [ ! -d "$BACKUP_DIR" ]; then
    echo "Backup directory not found: $BACKUP_DIR"
    exit 1
fi

echo "Restoring from backup: $BACKUP_DATE"

# Stop all services
cd ~/home-automation/stacks/home-automation
docker compose down
cd ~/home-automation/stacks/portainer
docker compose down

# Restore each volume
for backup_file in "$BACKUP_DIR"/*.tar.gz; do
    volume_name=$(basename "$backup_file" .tar.gz)
    echo "Restoring volume: $volume_name"

    docker run --rm \
        -v "$volume_name:/target" \
        -v "$BACKUP_DIR:/backup:ro" \
        alpine sh -c "rm -rf /target/* /target/.* 2>/dev/null || true; tar xzf /backup/$(basename $backup_file) -C /target"
done

# Restart services
cd ~/home-automation/stacks/portainer
docker compose up -d
cd ~/home-automation/stacks/home-automation
docker compose up -d

echo "Restore completed!"
```

## 🔍 Browse Backup Contents

### List Available Backups

```bash
# Daily backups
ls -lt /home/cliffm/backups/daily/

# Weekly backups
ls -lt /home/cliffm/backups/weekly/

# Monthly backups
ls -lt /home/cliffm/backups/monthly/
```

### Check Backup Size and Contents

```bash
# Check backup manifest
cat /home/cliffm/backups/daily/LATEST_DATE/MANIFEST.txt | tail -5

# List volume backups
ls -lah /home/cliffm/backups/daily/LATEST_DATE/volumes/

# Check total backup size
du -sh /home/cliffm/backups/daily/LATEST_DATE/
```

## 📂 Extract Individual Files

### Extract Single File from Home Assistant Backup

```bash
# Extract specific file without full restore
BACKUP_DATE="20250823_210931"  # Replace with your backup date

# Create temp directory and extract
mkdir -p /tmp/ha_extract
cd /tmp/ha_extract

# Extract Home Assistant backup
tar xzf "/home/cliffm/backups/daily/$BACKUP_DATE/volumes/home-automation_home_assistant_config.tar.gz"

# Now browse files
ls -la
# Files are now in /tmp/ha_extract/
```

## 🏥 Health Checks After Restore

### Verify Services After Restore

```bash
# Check all containers are running
docker compose ps

# Check Home Assistant is accessible
curl -f http://localhost:8123/manifest.json && echo "✅ HA OK"

# Check Node-RED is accessible
curl -f http://localhost:1880/ && echo "✅ Node-RED OK"

# Check MQTT is working
docker exec mosquitto mosquitto_pub -h localhost -t test -m "restore test" && echo "✅ MQTT OK"

# Check Z-Wave devices
# Access http://ha-server2:8091 and verify devices are visible
```
