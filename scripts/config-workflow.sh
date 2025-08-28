#!/bin/bash
# config-workflow.sh - Git-aware configuration management

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
    echo "Home Automation Configuration Management"
    echo ""
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  backup          - Pull configs from containers and commit to git"
    echo "  deploy          - Deploy configs from git to containers"
    echo "  status          - Show configuration status"
    echo ""
    echo "Examples:"
    echo "  $0 backup       # Backup all configs and commit"
    echo "  $0 deploy       # Deploy configs from git"
    echo "  $0 status       # Show status"
    exit 1
}

# Backup workflow with git integration
backup_configs() {
    echo -e "${BLUE}=== BACKUP WORKFLOW ===${NC}\n"
    
    # Pull configs from volumes
    "$REPO_ROOT/scripts/sync-configs.sh" pull
    
    # Check for changes
    if git diff --quiet && git diff --cached --quiet; then
        echo -e "${GREEN}No configuration changes detected${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}Configuration changes detected:${NC}"
    git status --porcelain
    
    # Interactive commit
    read -p "Create backup commit? (Y/n): " confirm
    if [[ ! $confirm =~ ^[Nn]$ ]]; then
        local timestamp=$(date '+%Y-%m-%d %H:%M')
        local changed_services=$(git diff --name-only | grep '^configs/' | cut -d'/' -f2 | sort -u | tr '\n' ' ' || echo "")
        
        git add configs/
        git commit -m "Config backup: $timestamp

Services updated: $changed_services

Auto-backup from Docker volumes"
        
        echo -e "${GREEN}✓ Backup committed to git${NC}"
        
        # Push to remote if configured
        if git remote | grep -q origin 2>/dev/null; then
            read -p "Push to remote repository? (Y/n): " push_confirm
            if [[ ! $push_confirm =~ ^[Nn]$ ]]; then
                git push
                echo -e "${GREEN}✓ Pushed to remote repository${NC}"
            fi
        fi
    fi
}

# Deploy workflow with safety checks
deploy_configs() {
    echo -e "${BLUE}=== DEPLOY WORKFLOW ===${NC}\n"
    
    # Safety checks
    if [ -n "$(git status --porcelain)" ]; then
        echo -e "${YELLOW}Warning: You have uncommitted changes${NC}"
        git status --short
        read -p "Continue with deployment? (y/N): " confirm
        if [[ ! $confirm =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    # Show what will be deployed
    echo -e "${BLUE}Deploying configurations from git commit:${NC}"
    git log -1 --oneline
    
    read -p "Proceed with deployment? (y/N): " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        exit 1
    fi
    
    # Deploy
    "$REPO_ROOT/scripts/sync-configs.sh" push
    
    echo -e "${GREEN}✓ Configuration deployed${NC}"
    echo -e "${YELLOW}Remember to restart affected containers if needed${NC}"
}

# Main script
if [ $# -eq 0 ]; then
    echo -e "${BLUE}=== HOME AUTOMATION CONFIG MANAGEMENT ===${NC}\n"
    echo "What would you like to do?"
    echo "1) Backup current configs to git"
    echo "2) Deploy configs from git to containers"
    echo "3) Show status"
    echo "4) Exit"
    
    read -p "Choose (1-4): " choice
    
    case $choice in
        1) backup_configs ;;
        2) deploy_configs ;;
        3) "$REPO_ROOT/scripts/sync-configs.sh" status ;;
        4) exit 0 ;;
        *) echo "Invalid option" ;;
    esac
    exit 0
fi

COMMAND=$1

case $COMMAND in
    backup)
        backup_configs
        ;;
    deploy)
        deploy_configs
        ;;
    status)
        "$REPO_ROOT/scripts/sync-configs.sh" status
        ;;
    *)
        echo -e "${RED}Error: Unknown command '$COMMAND'${NC}"
        usage
        ;;
esac
