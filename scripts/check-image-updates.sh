#!/usr/bin/env bash
# =============================================================================
# check-image-updates.sh
# Scans docker-compose files for image references and checks each registry's
# tag list for newer versions: a newer patch in the same release line, and a
# newer release line (minor/major) when one exists.
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
MAX_PAGES=50        # tag-list pages (1000 tags each) to read per repo

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
# Registry helpers (Docker Registry HTTP API v2: Docker Hub, ghcr.io, lscr.io,
# quay.io, ...). Public images only; no credentials are sent.
# --------------------------------------------------------------------------- #

# API host for a registry name as written in an image reference.
registry_host() {
  case "$1" in
    docker.io) echo "registry-1.docker.io" ;;
    *)         echo "$1" ;;
  esac
}

# Anonymous pull token for a repo, obtained by answering the registry's
# 'WWW-Authenticate: Bearer realm=...,service=...' challenge.
# Prints nothing when the registry needs no token.
registry_token() {
  local host="$1" repo="$2" challenge realm service
  # GET, not HEAD: ghcr.io answers HEAD on /v2/ with 405 and no challenge
  challenge=$(curl -s -o /dev/null -D - --max-time "$TIMEOUT" "https://${host}/v2/" \
    | tr -d '\r' | grep -i '^www-authenticate: *bearer' | head -1) || true
  [[ -z "$challenge" ]] && return 0
  realm=$(sed -n 's/.*realm="\([^"]*\)".*/\1/p' <<< "$challenge")
  service=$(sed -n 's/.*service="\([^"]*\)".*/\1/p' <<< "$challenge")
  [[ -z "$realm" ]] && return 0
  curl -sf --max-time "$TIMEOUT" -G "$realm" \
    --data-urlencode "service=${service}" \
    --data-urlencode "scope=repository:${repo}:pull" \
    | jq -r '.token // .access_token // empty'
}

# Print every tag of a repo, one per line. Follows Link-header pagination.
# Fails (non-zero) if any page cannot be fetched, so a partial list is never
# mistaken for the full one.
registry_tags() {
  local host="$1" repo="$2"
  local token url hdr body link page=0
  local -a auth=()
  token=$(registry_token "$host" "$repo") || true
  [[ -n "$token" ]] && auth=(-H "Authorization: Bearer ${token}")

  url="https://${host}/v2/${repo}/tags/list?n=1000"
  hdr=$(mktemp)
  while [[ -n "$url" && $page -lt $MAX_PAGES ]]; do
    body=$(curl -sf --max-time "$TIMEOUT" "${auth[@]}" -D "$hdr" "$url") \
      || { rm -f "$hdr"; return 1; }
    jq -r '.tags[]? // empty' <<< "$body"

    link=$(tr -d '\r' < "$hdr" | grep -i '^link:' \
      | grep -o '<[^>]*>' | tr -d '<>' | head -1) || true
    case "$link" in
      "")    url="" ;;
      http*) url="$link" ;;
      *)     url="https://${host}${link}" ;;
    esac
    page=$((page + 1))
  done
  rm -f "$hdr"
}

# Print the manifest digest a tag currently points to (from the
# Docker-Content-Digest response header).
registry_digest() {
  local host="$1" repo="$2" ref="$3"
  local token
  local -a auth=()
  token=$(registry_token "$host" "$repo") || true
  [[ -n "$token" ]] && auth=(-H "Authorization: Bearer ${token}")

  curl -sI --max-time "$TIMEOUT" "${auth[@]}" \
    -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json" \
    "https://${host}/v2/${repo}/manifests/${ref}" \
    | tr -d '\r' | grep -i '^docker-content-digest:' | awk '{print $2}'
}

# --------------------------------------------------------------------------- #
# Version comparison
# --------------------------------------------------------------------------- #

VERSION_TAG_RE='^(v?)([0-9]+(\.[0-9]+)*)(-.+)?$'

# Given the current tag and the repo's tag list, print "PATCH|LINE|KIND":
#   PATCH  newest tag in the same release line (same MAJOR.MINOR), if newer
#   LINE   newest tag overall when it is in a newer release line
#   KIND   "minor" or "major" for LINE
# Only tags written the same way as the current one are compared: same 'v'
# prefix, same number of version parts, same suffix. So 0.17.2 is compared
# with 0.18.2 (not a floating '0.18'), 2.1.2-alpine only with other -alpine
# tags, and pre-releases such as 2026.11.0b1 never match.
find_updates() {
  local current="$1" tags="$2"
  [[ "$current" =~ $VERSION_TAG_RE ]] || return 1
  local v="${BASH_REMATCH[1]}" ver="${BASH_REMATCH[2]}" suffix="${BASH_REMATCH[4]}"

  local -a parts
  IFS=. read -ra parts <<< "$ver"
  local n=${#parts[@]}

  local esc
  esc=$(printf '%s' "$suffix" | sed 's/[][\.*^$(){}+?|]/\\&/g')
  local shape="^${v}[0-9]+(\.[0-9]+){$((n - 1))}${esc}\$"

  # Bare versions (prefix and suffix stripped), oldest to newest
  local versions
  versions=$(printf '%s\n%s\n' "$tags" "$current" \
    | grep -E "$shape" \
    | sed -E "s/^${v}//; s/${esc}\$//" \
    | sort -uV)

  local newest patch="" line="" kind=""
  newest=$(tail -1 <<< "$versions")

  if [[ $n -ge 2 ]]; then
    local in_line
    in_line=$(grep -E "^${parts[0]}\.${parts[1]}(\.|\$)" <<< "$versions" | tail -1) || true
    [[ -n "$in_line" && "$in_line" != "$ver" ]] && patch="$in_line"
  fi

  if [[ "$newest" != "$ver" && "$newest" != "$patch" ]]; then
    line="$newest"
    if [[ "${newest%%.*}" != "${parts[0]}" ]]; then kind="major"; else kind="minor"; fi
  fi

  echo "${patch:+${v}${patch}${suffix}}|${line:+${v}${line}${suffix}}|${kind}"
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
    registry="$first_seg"
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
    registry="docker.io"
    [[ "$repo" != */* ]] && repo="library/${repo}"
  fi

  echo "$registry" "$repo" "$tag"
}

# --------------------------------------------------------------------------- #
# Per-image update check
# --------------------------------------------------------------------------- #
# Prints: compose_file|image_ref|registry|repo|tag|status|new_tag|line_tag|kind|note
check_image() {
  local compose_file="$1" image_ref="$2"
  local ref="$image_ref" pinned_digest=""
  if [[ "$ref" == *@* ]]; then
    pinned_digest="${ref#*@}"
    ref="${ref%%@*}"
  fi

  local registry repo tag host
  read -r registry repo tag <<< "$(parse_image "$ref")"
  host=$(registry_host "$registry")

  log_verbose "Checking: registry=${registry} repo=${repo} tag=${tag}"

  local status="" new_tag="" line_tag="" kind="" note=""

  if [[ -n "$pinned_digest" ]]; then
    # Pinned by digest: the only question is whether the tag has moved on.
    local now
    now=$(registry_digest "$host" "$repo" "$tag") || true
    if [[ -z "$now" ]]; then
      status="UNKNOWN"
    elif [[ "$now" == "$pinned_digest" ]]; then
      status="UP_TO_DATE"
    else
      status="UPDATE_AVAILABLE"
      note=":${tag} now points to ${now:0:19}… (pinned: ${pinned_digest:0:19}…)"
    fi
  elif [[ ! "$tag" =~ $VERSION_TAG_RE ]]; then
    status="FLOATING_TAG"
  else
    local tags
    tags=$(registry_tags "$host" "$repo") || tags=""
    if [[ -z "$tags" ]]; then
      status="UNKNOWN"
    else
      IFS='|' read -r new_tag line_tag kind <<< "$(find_updates "$tag" "$tags")"
      if [[ -n "$new_tag" || -n "$line_tag" ]]; then
        status="UPDATE_AVAILABLE"
      else
        status="UP_TO_DATE"
      fi
    fi
  fi

  echo "$compose_file|$image_ref|$registry|$repo|$tag|$status|$new_tag|$line_tag|$kind|$note"
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
    IFS='|' read -r compose_file image_ref registry repo tag status new_tag line_tag kind note <<< "$row"

    if [[ "$compose_file" != "$last_file" ]]; then
      echo ""
      echo -e "  ${BOLD}${CYAN}$(dirname "$compose_file" | xargs basename)/docker-compose.yml${RESET}"
      last_file="$compose_file"
    fi

    local icon status_color
    case "$status" in
      UPDATE_AVAILABLE) icon="⚠ "; status_color="$YELLOW"; (( updates++ )) || true ;;
      UP_TO_DATE)       icon="✓ "; status_color="$GREEN";  (( current++ )) || true ;;
      FLOATING_TAG)     icon="⬟ "; status_color="$CYAN";   (( pinned++  )) || true ;;
      *)                icon="? "; status_color="$RED";    (( unknown++ )) || true ;;
    esac

    printf "    %b%-14s%b  %s\n" "$status_color" "$status" "$RESET" "$image_ref"

    if $VERBOSE; then
      echo "              registry : $registry"
      echo "              repo     : $repo"
      echo "              tag      : $tag"
      [[ -n "$new_tag" ]]  && echo "              patch    : $new_tag"
      [[ -n "$line_tag" ]] && echo "              newer    : $line_tag ($kind)"
    fi

    if [[ "$status" == "UPDATE_AVAILABLE" ]]; then
      [[ -n "$new_tag" ]] && \
        echo -e "              ${YELLOW}→ update: ${tag} → ${new_tag}${RESET}"
      [[ -n "$line_tag" ]] && \
        echo -e "              ${YELLOW}→ newer release line: ${line_tag} (${kind})${RESET}"
      [[ -n "$note" ]] && \
        echo -e "              ${YELLOW}→ ${note}${RESET}"
    fi
  done

  echo ""
  echo -e "${BOLD}─────────────────────────────────────────────────────────────────${RESET}"
  echo -e "  Summary:"
  echo -e "    ${GREEN}✓ Up to date      : ${current}${RESET}"
  echo -e "    ${YELLOW}⚠ Update available: ${updates}${RESET}"
  echo -e "    ${CYAN}⬟ Floating tag    : ${pinned}${RESET}  (latest/stable etc. — run 'docker pull' to check)"
  echo -e "    ${RED}? Unknown/error   : ${unknown}${RESET}  (private/auth-required or unreachable)"
  echo -e "${BOLD}─────────────────────────────────────────────────────────────────${RESET}"
  echo ""

  if [[ $updates -gt 0 ]]; then
    echo -e "  ${YELLOW}${BOLD}Images with updates available:${RESET}"
    for row in "$@"; do
      IFS='|' read -r cf img _ _ _ status new_tag line_tag kind _ <<< "$row"
      [[ "$status" == "UPDATE_AVAILABLE" ]] || continue
      local target=""
      [[ -n "$new_tag" ]]  && target=" → ${new_tag}"
      [[ -n "$line_tag" ]] && target+="${target:+,} → ${line_tag} (${kind})"
      echo -e "    ${YELLOW}•${RESET} ${img}${target}  (in $(dirname "$cf" | xargs basename))"
    done
    echo ""
  fi

  if [[ $pinned -gt 0 ]]; then
    echo -e "  ${CYAN}Note:${RESET} Images on a floating tag (latest, stable, ...) cannot be compared by version."
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
  echo -e "${BOLD}Pattern: ${RESET} docker-compose.yml (any depth)"
  echo ""

  local -a all_rows=()
  local -A seen=()
  local key row

  while IFS='|' read -r compose_file image_ref; do
    key="${compose_file}::${image_ref}"
    [[ "${seen[$key]+_}" ]] && continue
    seen[$key]=1

    [ -t 1 ] && echo -ne "  Checking ${CYAN}${image_ref}${RESET} ...                    \r"

    row=$(check_image "$compose_file" "$image_ref")
    all_rows+=("$row")

  done < <(extract_images "$STACKS_DIR")

  [ -t 1 ] && echo -ne "                                                              \r"

  if [[ ${#all_rows[@]} -eq 0 ]]; then
    echo "No images found. Check --stacks-dir path."
    exit 1
  fi

  print_report "${all_rows[@]}"
}

main "$@"
