#!/bin/bash
# setup-config-sync.sh - Discover volumes and create sync infrastructure

set -e

echo "🔍 Discovering Docker volumes and container configurations..."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Create sync config file
SYNC_CONFIG="./scripts/sync-config.yaml"

echo "# Auto-generated sync configuration" > $SYNC_CONFIG
echo "# Edit this file to customize your sync behavior" >> $SYNC_CONFIG
echo "services:" >> $SYNC_CONFIG

# Function to discover service configs
discover_service() {
    local service_name=$1
    local container_name=$2
    
    echo -e "${BLUE}Checking service: $service_name${NC}"
    
    # Check if container exists and is running
    if docker ps --format "table {{.Names}}" | grep -q "^$container_name$"; then
        echo -e "${GREEN}✓ Container '$container_name' is running${NC}"
        
        # Get volume mounts
        echo "  Volume mounts:"
        docker inspect $container_name | jq -r '.[0].Mounts[] | select(.Type == "volume") | "    " + .Name + " -> " + .Destination'
        
        # Add to sync config
        echo "  $service_name:" >> $SYNC_CONFIG
        echo "    container: $container_name" >> $SYNC_CONFIG
        echo "    volumes:" >> $SYNC_CONFIG
        
        # Get volume details for sync config
        docker inspect $container_name | jq -r '.[0].Mounts[] | select(.Type == "volume") | "      - name: " + .Name + "\n        dest: " + .Destination + "\n        sync: true"' >> $SYNC_CONFIG
        
        echo "" >> $SYNC_CONFIG
        
    else
        echo -e "${YELLOW}⚠ Container '$container_name' not found or not running${NC}"
    fi
}

echo -e "\n${YELLOW}=== DISCOVERING YOUR SERVICES ===${NC}\n"

# Discover your specific services
discover_service "home-assistant" "home-assistant"
discover_service "frigate" "frigate"
discover_service "node-red" "node-red"
discover_service "mqtt" "mosquitto"

echo -e "\n${YELLOW}=== ALL RUNNING CONTAINERS ===${NC}"
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"

echo -e "\n${GREEN}=== SYNC CONFIGURATION CREATED ===${NC}"
echo "Configuration saved to: $SYNC_CONFIG"
echo -e "\n${BLUE}Next steps:${NC}"
echo "1. Review and edit $SYNC_CONFIG"
echo "2. Run './scripts/sync-configs.sh pull' to backup current configs"
echo "3. Run './scripts/sync-configs.sh push' to deploy configs from repo"
