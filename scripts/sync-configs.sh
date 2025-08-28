#!/bin/bash
# sync-configs.sh - Bidirectional sync between Docker volumes and git repo

set -e

# Configuration
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="$REPO_ROOT/configs"
SYNC_CONFIG="$REPO_ROOT/scripts/sync-config.yaml"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Usage function
usage() {
    echo "Usage: $0 [pull|push|status] [service_name]"
    echo ""
    echo "Commands:"
    echo "  pull     - Copy configs FROM Docker volumes TO git repo (backup)"
    echo "  push     - Copy configs FROM git repo TO Docker volumes (deploy)"
    echo "  status   - Show sync status and differences"
    echo ""
    echo "Options:"
    echo "  service_name - Optional: sync only specific service (home-assistant, frigate, node-red)"
    echo ""
    echo "Examples:"
    echo "  $0 pull                    # Backup all configs to repo"
    echo "  $0 push home-assistant     # Deploy only Home Assistant config"
    echo "  $0 status                  # Check status"
    exit 1
}

# Simple YAML parser (since yq might not be available)
parse_yaml() {
    local yaml_file=$1
    local service=$2
    local field=$3
    
    if [ "$field" = "container" ]; then
        grep -A 1 "^  $service:" "$yaml_file" | grep "container:" | awk '{print $2}'
    fi
}

# Get volume info from docker inspect
get_volumes() {
    local container=$1
    docker inspect $container 2>/dev/null | jq -r '.[0].Mounts[]? | select(.Type == "volume") | .Name + "|" + .Destination' 2>/dev/null || echo ""
}

# Function to sync a specific service
sync_service() {
    local service=$1
    local direction=$2  # pull or push
    
    echo -e "${BLUE}Syncing service: $service ($direction)${NC}"
    
    # Get container name based on service
    local container=""
    case $service in
        "home-assistant") container="home-assistant" ;;
        "frigate") container="frigate" ;;
        "node-red") container="node-red" ;;
        "mqtt") container="mosquitto" ;;
        *) echo -e "${RED}Unknown service: $service${NC}"; return 1 ;;
    esac
    
    # Check if container is running
    if ! docker ps --format "{{.Names}}" | grep -q "^$container$"; then
        echo -e "${YELLOW}⚠ Container '$container' is not running, skipping...${NC}"
        return 1
    fi
    
    # Create service config directory
    mkdir -p "$CONFIG_DIR/$service"
    
    # Get volumes for this container
    local volumes=$(get_volumes $container)
    
    if [ -z "$volumes" ]; then
        echo -e "${YELLOW}No volumes found for $container${NC}"
        return 1
    fi
    
    echo "$volumes" | while IFS='|' read -r volume_name dest_path; do
        if [ -z "$volume_name" ]; then continue; fi
        
        echo "  Volume: $volume_name -> $dest_path"
        
        if [ "$direction" = "pull" ]; then
            # Copy FROM volume TO repo
            echo "    Backing up to repo..."
            docker run --rm \
                -v "$volume_name:/source:ro" \
                -v "$CONFIG_DIR/$service:/dest" \
                alpine sh -c "
                    mkdir -p /dest
                    if [ -d /source ]; then
                        # Copy everything from the volume
                        cp -r /source/. /dest/ 2>/dev/null || true
                    fi
                    chmod -R 755 /dest/ 2>/dev/null || true
                "
        
        elif [ "$direction" = "push" ]; then
            # Copy FROM repo TO volume
            echo "    Deploying from repo..."
            
            # Safety check - ask for confirmation
            echo -e "${YELLOW}    This will overwrite configs in Docker volume '$volume_name'${NC}"
            read -p "    Continue? (y/N): " confirm
            if [[ ! $confirm =~ ^[Yy]$ ]]; then
                echo "    Skipping..."
                continue
            fi
            
            docker run --rm \
                -v "$CONFIG_DIR/$service:/source:ro" \
                -v "$volume_name:/dest" \
                alpine sh -c "
                    if [ -d /source ]; then
                        cp -r /source/. /dest/ 2>/dev/null || true
                    fi
                "
                
            echo -e "${GREEN}    ✓ Deployed to $volume_name${NC}"
            echo -e "${YELLOW}    Remember to restart the '$container' container${NC}"
        fi
    done
}

# Function to show status
show_status() {
    echo -e "${BLUE}=== SYNC STATUS ===${NC}\n"
    
    local services=("home-assistant" "frigate" "node-red" "mqtt")
    
    for service in "${services[@]}"; do
        local container=""
        case $service in
            "home-assistant") container="home-assistant" ;;
            "frigate") container="frigate" ;;
            "node-red") container="node-red" ;;
            "mqtt") container="mosquitto" ;;
        esac
        
        echo -e "${BLUE}Service: $service${NC}"
        echo "  Container: $container"
        
        if docker ps --format "{{.Names}}" | grep -q "^$container$"; then
            echo -e "  Status: ${GREEN}Running${NC}"
            
            # Check if config directory exists
            if [ -d "$CONFIG_DIR/$service" ]; then
                echo -e "  Repo config: ${GREEN}Present${NC}"
                local file_count=$(find "$CONFIG_DIR/$service" -type f 2>/dev/null | wc -l)
                echo "  Files in repo: $file_count"
            else
                echo -e "  Repo config: ${YELLOW}Missing${NC}"
            fi
        else
            echo -e "  Status: ${YELLOW}Not running${NC}"
        fi
        echo
    done
}

# Main script logic
if [ $# -lt 1 ]; then
    usage
fi

COMMAND=$1
SERVICE=${2:-""}

case $COMMAND in
    pull)
        echo -e "${GREEN}=== BACKING UP CONFIGS TO REPO ===${NC}\n"
        if [ -n "$SERVICE" ]; then
            sync_service "$SERVICE" "pull"
        else
            # Sync your main services
            for service in home-assistant frigate node-red mqtt; do
                sync_service "$service" "pull"
            done
        fi
        echo -e "\n${GREEN}✓ Backup complete! Don't forget to commit changes to git.${NC}"
        ;;
    
    push)
        echo -e "${YELLOW}=== DEPLOYING CONFIGS FROM REPO ===${NC}\n"
        if [ -n "$SERVICE" ]; then
            sync_service "$SERVICE" "push"
        else
            echo -e "${YELLOW}Deploying all services. This will overwrite Docker volume configs!${NC}"
            read -p "Are you sure? (y/N): " confirm
            if [[ ! $confirm =~ ^[Yy]$ ]]; then
                echo "Cancelled."
                exit 1
            fi
            
            # Sync your main services
            for service in home-assistant frigate node-red mqtt; do
                sync_service "$service" "push"
            done
        fi
        echo -e "\n${GREEN}✓ Deploy complete! Remember to restart affected containers.${NC}"
        ;;
    
    status)
        show_status
        ;;
    
    *)
        echo -e "${RED}Error: Unknown command '$COMMAND'${NC}"
        usage
        ;;
esac
