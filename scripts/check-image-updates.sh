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

  # ── Step 1: Identify the registry host (if any) ──────────────────────────
  # A registry hostname is the first slash-delimited segment that either
  # contains a dot, a colon, or equals 'localhost'.
  # IMPORTANT: Only check for registry host when the image contains a slash;
  # otherwise "name:tag" images (e.g. "influxdb:2.7") would be misidentified.
  local first_seg="${image%%/*}"
  local remainder="${image#*/}"    # everything after the first /

  if [[ "$image" == */* ]] && [[ "$first_seg" == *"."* || "$first_seg" == *":"* || "$first_seg" == "localhost" ]]; then
    # Custom registry — first_seg is hostname (possibly host:port)
    case "$first_seg" in
      ghcr.io)   registry="ghcr"       ;;
      *)         registry="$first_seg" ;;
    esac
    # remainder is now "org/repo" or "org/repo:tag"
    image="$remainder"
  fi
  # If no custom registry detected, image is still the full string
  # and registry will be set to "dockerhub" below.

  # ── Step 2: Split tag from repo ──────────────────────────────────────────
  # The tag follows the LAST colon, but only if that colon is not inside
  # a path segment that looks like a port (already stripped above).
  if [[ "$image" == *:* ]]; then
    tag="${image##*:}"
    repo="${image%:*}"
  else
    tag="latest"
    repo="$image"
  fi

  # ── Step 3: Finalise registry & repo ─────────────────────────────────────
  if [[ -z "$registry" ]]; then
    registry="dockerhub"
    # Official single-name images need the 'library/' prefix for registry API
    [[ "$repo" != */* ]] && repo="library/${repo}"
  fi

  echo "$registry" "$repo" "$tag"
}
# Fetch the multi-arch manifest list digest for a tag via the Hub API.
# Keep the full repo path including 'library/' for official images —
# hub.docker.com/v2/repositories/library/traefik != /repositories/traefik
dockerhub_hub_digest() {
  local repo="$1" tag="$2"
  curl -sf --max-time "$TIMEOUT" \
    "https://hub.docker.com/v2/repositories/${repo}/tags/${tag}" \
    2>/dev/null | jq -r '.digest // empty'
}
# Find the latest version tag for a Docker Hub image.
#
# Uses the registry v2 /tags/list API (not the Hub tags API) which returns
# tags in stable alphabetical order with no re-indexing surprises.
# Fetches up to 1000 tags, filters to clean semver-looking tags, and returns
# the highest by version sort.
#
# This intentionally does NOT try to match the :latest digest — that approach
# fails because the Hub tags list has unreliable ordering and old re-indexed
# tags with null digests pollute results.
dockerhub_latest_version_tag() {
  local repo="$1"

  # Auth token for the registry v2 API
  local token
  token=$(curl -sf --max-time "$TIMEOUT" \
    "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" \
    | jq -r '.token // empty') || { echo ""; return; }
  [[ -z "$token" ]] && { echo ""; return; }

  # Fetch up to 1000 tags (alphabetical, stable, no Hub ordering quirks)
  local tags_json
  tags_json=$(curl -sf --max-time "$TIMEOUT" \
    -H "Authorization: Bearer ${token}" \
    "https://registry-1.docker.io/v2/${repo}/tags/list?n=1000" \
    2>/dev/null) || { echo ""; return; }

  # Extract tags, filter to clean version strings, return highest by version sort
  echo "$tags_json" \
    | jq -r '.tags[]? // empty' \
    | grep -E '^v?[0-9]+\.[0-9]' \
    | grep -viE '(alpha|beta|-rc[0-9]|-dev|-nightly|-amd64|-arm|-windows|-nano|-ubuntu|-debug|-rootless|-fips|-ubi|-enterprise|-exemplar|-i386|-ppc)' \
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
      # Use Hub API for both digests — consistent multi-arch manifest list format
      current_digest=$(dockerhub_hub_digest "$repo" "$tag" 2>/dev/null || echo "")
      if [[ "$tag" != "latest" ]]; then
        latest_digest=$(dockerhub_hub_digest "$repo" "latest" 2>/dev/null || echo "")
        # If digests differ, resolve the human-readable version tag for :latest
        if [[ -n "$latest_digest" && "$latest_digest" != "$current_digest" ]]; then
          latest_tag=$(dockerhub_latest_version_tag "$repo" 2>/dev/null || echo "")
        fi
      else
        latest_digest="$current_digest"
      fi
      ;;
    ghcr)
      current_digest=$(ghcr_digest "$repo" "$tag" 2>/dev/null || echo "")
      if [[ "$tag" != "latest" ]]; then
        latest_digest=$(ghcr_digest "$repo" "latest" 2>/dev/null || echo "")
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

    # Section header per compose file
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

  # Collect all image references, deduplicated per-file
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

  echo -ne "                                                              \r"  # clear progress line

  if [[ ${#all_rows[@]} -eq 0 ]]; then
    echo "No images found. Check --stacks-dir path."
    exit 1
  fi

  print_report "${all_rows[@]}"
}

main "$@"

