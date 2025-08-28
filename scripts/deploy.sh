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
