#!/usr/bin/env bash
# =============================================================================
# check-image-updates.sh
# Scans docker-compose files for image references and checks registries
# for newer versions.
#
# Usage:
#   ./check-image-updates.sh [--stacks-dir PATH] [--verbose]
#
# Requirements: curl, jq
# =============================================================================

set -euo pipefail

# Load .env if present
[[ -f "$(dirname "$0")/.env" ]] && source "$(dirname "$0")/.env"

# --------------------------------------------------------------------------- #
# Defaults
# --------------------------------------------------------------------------- #
STACKS_DIR="${STACKS_DIR:-$(pwd)}"
VERBOSE=false
TIMEOUT=10          # seconds per registry API call
COMPOSE_GLOB="*/docker-compose.yml"

# Colour codes (disabled if not a tty)
if [ -t 1 ]; then
  RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
fi

# --------------------------------------------------------------------------- #
# Argument parsing
# --------------------------------------------------------------------------- #
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stacks-dir) STACKS_DIR="$2"; shift 2 ;;
    --verbose|-v)  VERBOSE=true; shift ;;
    --help|-h)
      grep '^#' "$0" | head -10 | sed 's/^# \{0,2\}//'
      exit 0 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
log_verbose() { $VERBOSE && echo -e "  ${CYAN}[debug]${RESET} $*" >&2 || true; }

check_deps() {
  local missing=()
  for cmd in curl jq; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo -e "${RED}ERROR:${RESET} Missing required tools: ${missing[*]}"
    echo "Install with: sudo apt-get install -y ${missing[*]}"
    exit 1
  fi
}

# --------------------------------------------------------------------------- #
# GHCR helpers
# --------------------------------------------------------------------------- #

# Resolve a Bearer token for a GHCR repo via anonymous token exchange.
# Works for all public GHCR images without credentials.
# Note: a PAT cannot be used directly as a Bearer token — it requires
# Basic auth to exchange for a bearer token, which also needs a username.
# Anonymous exchange covers all public images so we use it unconditionally.
ghcr_token() {
  local repo="$1"
  curl -sf --max-time "$TIMEOUT" \
    "https://ghcr.io/token?service=ghcr.io&scope=repository:${repo}:pull" \
    | jq -r '.token // empty'
}

# Fetch the manifest digest for a GHCR image:tag.
# The canonical digest lives in the Docker-Content-Digest response header,
# not the JSON body (which only has config.digest for single-arch images).
ghcr_digest() {
  local repo="$1" tag="$2"
  local token
  token=$(ghcr_token "$repo") || { echo ""; return; }
  [[ -z "$token" ]] && { echo ""; return; }

  curl -sI --max-time "$TIMEOUT" \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json" \
    "https://ghcr.io/v2/${repo}/manifests/${tag}" \
    | grep -i '^Docker-Content-Digest:' \
    | tr -d '\r' \
    | awk '{print $2}'
}

# Find the latest version tag for a GHCR image, matching the current tag's
# family (v-prefix + variant suffix). Paginates via Link headers.
ghcr_latest_version_tag() {
  local repo="$1" current_tag="$2"

  local v_prefix="" suffix=""
  if [[ "$current_tag" =~ ^(v?)([0-9]+(\.[0-9]+)*)(-.+)?$ ]]; then
    v_prefix="${BASH_REMATCH[1]}"
    suffix="${BASH_REMATCH[4]}"
  fi

  local escaped_suffix
  escaped_suffix=$(printf '%s' "$suffix" | sed 's/[.[\*^$(){}+?|]/\\&/g')

  local pattern
  if [[ -n "$suffix" ]]; then
    pattern="^${v_prefix}[0-9]+(\.[0-9]+)+(${escaped_suffix})$"
  else
    pattern="^${v_prefix}[0-9]+(\.[0-9]+)+$"
  fi

  local token
  token=$(ghcr_token "$repo") || { echo ""; return; }
  [[ -z "$token" ]] && { echo ""; return; }

  local all_tags="" next_url="https://ghcr.io/v2/${repo}/tags/list?n=1000"
  local max_pages=10 page=0 hdr_file
  hdr_file=$(mktemp)

  while [[ -n "$next_url" && $page -lt $max_pages ]]; do
    local body link_path
    body=$(curl -sf --max-time "$TIMEOUT" \
      -H "Authorization: Bearer ${token}" \
      -D "$hdr_file" \
      "$next_url" 2>/dev/null) || break

    all_tags+=$(printf '%s' "$body" | jq -r '.tags[]? // empty')$'\n'

    link_path=$(grep -i '^[Ll]ink:' "$hdr_file" \
      | grep -o '<[^>]*>' | tr -d '<>' | head -1)

    if [[ -n "$link_path" ]]; then
      next_url="https://ghcr.io${link_path}"
    else
      next_url=""
    fi
    (( page++ ))
  done
  rm -f "$hdr_file"

  printf '%s' "$all_tags" \
    | grep -E "$pattern" \
    | grep -viE '(alpha|beta|rc[0-9]|-dev|-nightly)' \
    | sort -V \
    | tail -1
}

# --------------------------------------------------------------------------- #
# Image parsing
# --------------------------------------------------------------------------- #

# Extract image lines from compose files, return "file|image:tag" pairs
extract_images() {
  local dir="$1"
  local -a results=()

  while IFS= read -r compose_file; do
    while IFS= read -r line; do
      # Match lines like:  image: something:tag  or  image: something
      if [[ "$line" =~ ^[[:space:]]*image:[[:space:]]*([^[:space:]#]+) ]]; then
        local raw="${BASH_REMATCH[1]}"
        # Strip surrounding quotes if any
        raw="${raw//\"/}"
        raw="${raw//\'/}"
        [[ -z "$raw" ]] && continue
        results+=("${compose_file}|${raw}")
      fi
    done < "$compose_file"
  done < <(find "$dir" -name "docker-compose.yml" -not -path "*/node_modules/*")

  # Safe expansion — avoids set -u failure on empty array
  [[ ${#results[@]} -gt 0 ]] && printf '%s\n' "${results[@]}"
}

# Parse an image string into registry, repo, and tag components.
# Handles: official images, org/image:tag, ghcr.io/..., lscr.io/...,
#          host.tld:port/repo:tag, numeric-only tags (eclipse-mosquitto:2).
# Outputs: registry repo tag
parse_image() {
  local image="$1"
  local registry="" repo="" tag=""

  local first_seg="${image%%/*}"
  local remainder="${image#*/}"

  if [[ "$image" == */* ]] && [[ "$first_seg" == *"."* || "$first_seg" == *":"* || "$first_seg" == "localhost" ]]; then
    case "$first_seg" in
      ghcr.io)   registry="ghcr"       ;;
      *)         registry="$first_seg" ;;
    esac
    image="$remainder"
  fi

  if [[ "$image" == *:* ]]; then
    tag="${image##*:}"
    repo="${image%:*}"
  else
    tag="latest"
    repo="$image"
  fi

  if [[ -z "$registry" ]]; then
    registry="dockerhub"
    [[ "$repo" != */* ]] && repo="library/${repo}"
  fi

  echo "$registry" "$repo" "$tag"
}

# --------------------------------------------------------------------------- #
# Docker Hub helpers
# --------------------------------------------------------------------------- #

dockerhub_hub_digest() {
  local repo="$1" tag="$2"
  curl -sf --max-time "$TIMEOUT" \
    "https://hub.docker.com/v2/repositories/${repo}/tags/${tag}" \
    2>/dev/null | jq -r '.digest // empty'
}

dockerhub_latest_version_tag() {
  local repo="$1" current_tag="$2"

  local v_prefix="" suffix=""
  if [[ "$current_tag" =~ ^(v?)([0-9]+(\.[0-9]+)*)(-.+)?$ ]]; then
    v_prefix="${BASH_REMATCH[1]}"
    suffix="${BASH_REMATCH[4]}"
  fi

  local escaped_suffix
  escaped_suffix=$(printf '%s' "$suffix" | sed 's/[.[\*^$(){}+?|]/\\&/g')

  local pattern
  if [[ -n "$suffix" ]]; then
    pattern="^${v_prefix}[0-9]+(\.[0-9]+)+(${escaped_suffix})$"
  else
    pattern="^${v_prefix}[0-9]+(\.[0-9]+)+$"
  fi

  local token
  token=$(curl -sf --max-time "$TIMEOUT" \
    "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" \
    | jq -r '.token // empty') || { echo ""; return; }
  [[ -z "$token" ]] && { echo ""; return; }

  local all_tags="" next_url="https://registry-1.docker.io/v2/${repo}/tags/list?n=1000"
  local max_pages=10 page=0 hdr_file
  hdr_file=$(mktemp)

  while [[ -n "$next_url" && $page -lt $max_pages ]]; do
    local body link_path
    body=$(curl -sf --max-time "$TIMEOUT" \
      -H "Authorization: Bearer ${token}" \
      -D "$hdr_file" \
      "$next_url" 2>/dev/null) || break

    all_tags+=$(printf '%s' "$body" | jq -r '.tags[]? // empty')$'\n'

    link_path=$(grep -i '^[Ll]ink:' "$hdr_file" \
      | grep -o '<[^>]*>' | tr -d '<>' | head -1)

    if [[ -n "$link_path" ]]; then
      next_url="https://registry-1.docker.io${link_path}"
    else
      next_url=""
    fi
    (( page++ ))
  done
  rm -f "$hdr_file"

  printf '%s' "$all_tags" \
    | grep -E "$pattern" \
    | grep -viE '(alpha|beta|rc[0-9]|-dev|-nightly)' \
    | sort -V \
    | tail -1
}

# --------------------------------------------------------------------------- #
# Per-image update check
# --------------------------------------------------------------------------- #
check_image() {
  local compose_file="$1" image_ref="$2"
  local registry repo tag
  read -r registry repo tag <<< "$(parse_image "$image_ref")"

  log_verbose "Checking: registry=${registry} repo=${repo} tag=${tag}"

  local current_digest="" latest_digest="" status="" latest_tag=""

  case "$registry" in
    dockerhub)
      current_digest=$(dockerhub_hub_digest "$repo" "$tag" 2>/dev/null || echo "")
      if [[ "$tag" != "latest" ]]; then
        latest_digest=$(dockerhub_hub_digest "$repo" "latest" 2>/dev/null || echo "")
        if [[ -n "$latest_digest" && "$latest_digest" != "$current_digest" ]]; then
          latest_tag=$(dockerhub_latest_version_tag "$repo" "$tag" 2>/dev/null || echo "")
          if [[ -n "$latest_tag" && "$latest_tag" == "$tag" ]]; then
            latest_digest="$current_digest"
            latest_tag=""
          fi
        fi
      else
        latest_digest="$current_digest"
      fi
      ;;
    ghcr)
      current_digest=$(ghcr_digest "$repo" "$tag" 2>/dev/null || echo "")
      if [[ "$tag" != "latest" && "$tag" != "stable" ]]; then
        latest_digest=$(ghcr_digest "$repo" "latest" 2>/dev/null || echo "")
        if [[ -n "$latest_digest" && "$latest_digest" != "$current_digest" ]]; then
          latest_tag=$(ghcr_latest_version_tag "$repo" "$tag" 2>/dev/null || echo "")
          if [[ -n "$latest_tag" && "$latest_tag" == "$tag" ]]; then
            latest_digest="$current_digest"
            latest_tag=""
          fi
        fi
      else
        latest_digest="$current_digest"
      fi
      ;;
    *)
      current_digest=$(generic_digest "$registry" "$repo" "$tag" 2>/dev/null || echo "")
      if [[ "$tag" != "latest" ]]; then
        latest_digest=$(generic_digest "$registry" "$repo" "latest" 2>/dev/null || echo "")
      else
        latest_digest="$current_digest"
      fi
      ;;
  esac

  # Determine status
  if [[ -z "$current_digest" ]]; then
    status="UNKNOWN"
  elif [[ "$tag" == "latest" || "$tag" == "stable" ]]; then
    status="PINNED_LATEST"
  elif [[ -z "$latest_digest" ]]; then
    status="NO_LATEST_TAG"
  elif [[ "$current_digest" == "$latest_digest" ]]; then
    status="UP_TO_DATE"
  else
    status="UPDATE_AVAILABLE"
  fi

  echo "$compose_file|$image_ref|$registry|$repo|$tag|$status|$latest_tag"
}

# --------------------------------------------------------------------------- #
# Reporting
# --------------------------------------------------------------------------- #
print_report() {
  local results=("$@")
  local updates=0 unknown=0 pinned=0 current=0

  echo ""
  echo -e "${BOLD}═══════════════════════════════════════════════════════════════${RESET}"
  echo -e "${BOLD}  Docker Image Update Report${RESET}"
  echo -e "${BOLD}  Generated: $(date '+%Y-%m-%d %H:%M:%S')${RESET}"
  echo -e "${BOLD}═══════════════════════════════════════════════════════════════${RESET}"

  local last_file=""
  for row in "$@"; do
    IFS='|' read -r compose_file image_ref registry repo tag status latest_tag <<< "$row"

    if [[ "$compose_file" != "$last_file" ]]; then
      echo ""
      echo -e "  ${BOLD}${CYAN}$(dirname "$compose_file" | xargs basename)/docker-compose.yml${RESET}"
      last_file="$compose_file"
    fi

    local icon status_color
    case "$status" in
      UPDATE_AVAILABLE) icon="⚠ "; status_color="$YELLOW"; (( updates++ )) || true ;;
      UP_TO_DATE)       icon="✓ "; status_color="$GREEN";  (( current++ )) || true ;;
      PINNED_LATEST)    icon="⬟ "; status_color="$CYAN";   (( pinned++  )) || true ;;
      *)                icon="? "; status_color="$RED";    (( unknown++ )) || true ;;
    esac

    printf "    %b%-14s%b  %s\n" "$status_color" "$status" "$RESET" "$image_ref"

    if $VERBOSE; then
      echo "              registry : $registry"
      echo "              repo     : $repo"
      echo "              tag      : $tag"
      [[ -n "$latest_tag" ]] && echo "              latest   : $latest_tag"
    fi

    if [[ "$status" == "UPDATE_AVAILABLE" ]]; then
      if [[ -n "$latest_tag" ]]; then
        echo -e "              ${YELLOW}→ update: ${tag} → ${latest_tag}${RESET}"
      else
        echo -e "              ${YELLOW}→ update available (run docker pull to get latest)${RESET}"
      fi
    fi
  done

  echo ""
  echo -e "${BOLD}─────────────────────────────────────────────────────────────────${RESET}"
  echo -e "  Summary:"
  echo -e "    ${GREEN}✓ Up to date      : ${current}${RESET}"
  echo -e "    ${YELLOW}⚠ Update available: ${updates}${RESET}"
  echo -e "    ${CYAN}⬟ Pinned :latest  : ${pinned}${RESET}  (tag ambiguous — run 'docker pull' to check)"
  echo -e "    ${RED}? Unknown/error   : ${unknown}${RESET}  (private/auth-required or unreachable)"
  echo -e "${BOLD}─────────────────────────────────────────────────────────────────${RESET}"
  echo ""

  if [[ $updates -gt 0 ]]; then
    echo -e "  ${YELLOW}${BOLD}Images with updates available:${RESET}"
    for row in "$@"; do
      IFS='|' read -r cf img _ _ _ status _ <<< "$row"
      [[ "$status" == "UPDATE_AVAILABLE" ]] && \
        echo -e "    ${YELLOW}•${RESET} $img  (in $(dirname "$cf" | xargs basename))"
    done
    echo ""
  fi

  if [[ $pinned -gt 0 ]]; then
    echo -e "  ${CYAN}Note:${RESET} Images using ':latest' tag cannot be reliably compared."
    echo -e "        Run ${BOLD}docker compose pull${RESET} in each stack directory to refresh them."
    echo ""
  fi
}

# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #
main() {
  check_deps

  echo -e "${BOLD}Scanning:${RESET} ${STACKS_DIR}"
  echo -e "${BOLD}Pattern: ${RESET} ${COMPOSE_GLOB}"
  echo ""

  local -a all_rows=()
  local -A seen=()
  local key row

  while IFS='|' read -r compose_file image_ref; do
    key="${compose_file}::${image_ref}"
    [[ "${seen[$key]+_}" ]] && continue
    seen[$key]=1

    echo -ne "  Checking ${CYAN}${image_ref}${RESET} ...                    \r"

    row=$(check_image "$compose_file" "$image_ref")
    all_rows+=("$row")

  done < <(extract_images "$STACKS_DIR")

  echo -ne "                                                              \r"

  if [[ ${#all_rows[@]} -eq 0 ]]; then
    echo "No images found. Check --stacks-dir path."
    exit 1
  fi

  print_report "${all_rows[@]}"
}

main "$@"
