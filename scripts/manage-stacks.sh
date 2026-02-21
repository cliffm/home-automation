#!/bin/bash
# manage-stacks.sh - Start/stop all Docker Compose stacks
# Usage: manage-stacks.sh [start|stop|restart|status] [stack_name]
#
# Stacks are started/stopped in dependency order:
#   Start order: portainer → traefik → monitoring → home-automation → frigate → watchtower
#   Stop order:  reverse of start

STACKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../stacks" && pwd)"

# Ordered list for startup (dependencies first)
ORDERED_STACKS=(
    portainer
    traefik
    monitoring
    home-automation
    frigate
    watchtower
)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }

# Verify a stack directory exists and has a compose file
stack_exists() {
    local stack="$1"
    [[ -f "${STACKS_DIR}/${stack}/docker-compose.yml" ]]
}

# Run docker compose command for a single stack
compose_cmd() {
    local action="$1"
    local stack="$2"
    local compose_file="${STACKS_DIR}/${stack}/docker-compose.yml"

    if ! stack_exists "$stack"; then
        log_error "Stack '${stack}' not found at ${compose_file}"
        return 1
    fi

    log_info "${action^} stack: ${stack}"
    if docker compose -f "$compose_file" --project-name "$stack" "$action"; then
        log_ok "Stack '${stack}' ${action} complete"
        return 0
    else
        log_error "Stack '${stack}' ${action} failed (exit $?)"
        return 1
    fi
}

# Print status for all (or one) stack
stack_status() {
    local target="${1:-}"
    local stacks=()

    if [[ -n "$target" ]]; then
        stacks=("$target")
    else
        stacks=("${ORDERED_STACKS[@]}")
    fi

    echo ""
    printf "%-20s %-10s %s\n" "STACK" "STATUS" "SERVICES"
    printf "%-20s %-10s %s\n" "-----" "------" "--------"

    for stack in "${stacks[@]}"; do
        if ! stack_exists "$stack"; then
            printf "%-20s %-10s %s\n" "$stack" "MISSING" "-"
            continue
        fi

        compose_file="${STACKS_DIR}/${stack}/docker-compose.yml"
        running=$(docker compose -f "$compose_file" --project-name "$stack" ps --services --filter status=running 2>/dev/null | wc -l)
        total=$(docker compose -f "$compose_file" --project-name "$stack" ps --services 2>/dev/null | wc -l)

        if [[ "$running" -eq 0 && "$total" -eq 0 ]]; then
            status="${RED}DOWN${NC}"
        elif [[ "$running" -lt "$total" ]]; then
            status="${YELLOW}PARTIAL${NC}"
        else
            status="${GREEN}UP${NC}"
        fi

        printf "%-20s ${status}%-$((10 - ${#status} + ${#NC} + ${#GREEN}))s %s\n" \
            "$stack" "" "${running}/${total} running"
    done
    echo ""
}

do_start() {
    local target="${1:-}"
    local errors=0

    if [[ -n "$target" ]]; then
        compose_cmd up -d "$target" || ((errors++))
    else
        log_info "Starting all stacks in dependency order..."
        for stack in "${ORDERED_STACKS[@]}"; do
            compose_cmd "up -d" "$stack" || ((errors++))
            sleep 2  # Brief pause between stacks
        done
    fi

    [[ $errors -eq 0 ]] && log_ok "All stacks started." || log_warn "${errors} stack(s) had errors."
}

do_stop() {
    local target="${1:-}"
    local errors=0

    if [[ -n "$target" ]]; then
        compose_cmd stop "$target" || ((errors++))
    else
        log_info "Stopping all stacks in reverse dependency order..."
        for (( i=${#ORDERED_STACKS[@]}-1; i>=0; i-- )); do
            compose_cmd stop "${ORDERED_STACKS[$i]}" || ((errors++))
        done
    fi

    [[ $errors -eq 0 ]] && log_ok "All stacks stopped." || log_warn "${errors} stack(s) had errors."
}

do_restart() {
    local target="${1:-}"
    log_info "Restarting..."
    do_stop "$target"
    sleep 3
    do_start "$target"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [stack_name]

Commands:
  start   [stack]   Start all stacks (or a specific one) in dependency order
  stop    [stack]   Stop all stacks (or a specific one) in reverse order
  restart [stack]   Stop then start all stacks (or a specific one)
  status  [stack]   Show running status of all stacks (or a specific one)

Available stacks:
  $(printf '%s\n  ' "${ORDERED_STACKS[@]}")

Examples:
  $(basename "$0") start                  # Start all stacks
  $(basename "$0") stop home-automation   # Stop only home-automation
  $(basename "$0") restart monitoring     # Restart monitoring stack
  $(basename "$0") status                 # Show status of all stacks

Stacks directory: ${STACKS_DIR}
EOF
}

# ── Main ──────────────────────────────────────────────────────────────────────

COMMAND="${1:-}"
TARGET="${2:-}"

# If a target stack is given, fix up compose_cmd to handle "up -d" vs single-word commands
# Redefine to handle start correctly with flags
compose_cmd() {
    local action="$1"
    local stack="$2"
    local compose_file="${STACKS_DIR}/${stack}/docker-compose.yml"

    if ! stack_exists "$stack"; then
        log_error "Stack '${stack}' not found at ${compose_file}"
        return 1
    fi

    log_info "${action} stack: ${stack}"
    # shellcheck disable=SC2086
    if docker compose -f "$compose_file" --project-name "$stack" $action; then
        log_ok "Stack '${stack}' → ${action} complete"
        return 0
    else
        log_error "Stack '${stack}' → ${action} failed"
        return 1
    fi
}

case "$COMMAND" in
    start)   do_start   "$TARGET" ;;
    stop)    do_stop    "$TARGET" ;;
    restart) do_restart "$TARGET" ;;
    status)  stack_status "$TARGET" ;;
    *)       usage; exit 1 ;;
esac

