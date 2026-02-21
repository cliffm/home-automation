#!/usr/bin/env python3
"""
check_compose_images_versions.py

Locate images used in docker-compose files and suggest upgrades as:
  OLD tag (what compose uses) -> NEW tag (newer tag available)

Features:
- Parses docker-compose*.yml files under --root
- Extracts services.*.image
- For Docker Hub images: lists tags via Docker Hub API and suggests newer version tags
- Color-coded STATUS:
    - UPGRADE (red): newer version available
    - CURRENT (green): already at newest matching tag (per heuristics)
    - FLOATING (yellow): tag is 'latest' or 'stable' (not a version tag)
    - UNSUPPORTED (yellow): non-Docker Hub registries (e.g., ghcr.io) not implemented
    - ERROR (red): Hub API error

Usage:
  ./check_compose_images_versions.py --root /home/cliffm/home-automation/stacks
  ./check_compose_images_versions.py --root . --glob '**/docker-compose*.yml'
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Dict, List, Optional, Set, Tuple


# ----------------------------
# Terminal color helpers
# ----------------------------

def supports_color() -> bool:
    return sys.stdout.isatty() and os.environ.get("NO_COLOR") is None

class C:
    if supports_color():
        GREEN = "\033[32m"
        YELLOW = "\033[33m"
        RED = "\033[31m"
        RESET = "\033[0m"
    else:
        GREEN = YELLOW = RED = RESET = ""


# ----------------------------
# Image ref parsing / normalize
# ----------------------------

@dataclass(frozen=True)
class ImageRef:
    raw: str
    registry: str          # docker.io, ghcr.io, ...
    repo: str              # library/nginx, user/app
    tag: str               # default 'latest' if absent
    normalized: str        # registry/repo:tag


def _split_image(s: str) -> Tuple[str, str, str]:
    """
    Returns (registry, repo, tag). Ignores @sha256 digests intentionally.
    """
    s = s.strip().strip('"').strip("'")
    if "@" in s:
        s = s.split("@", 1)[0].strip()

    # tag split (avoid mistaking registry port for tag)
    last_slash = s.rfind("/")
    last_colon = s.rfind(":")
    if last_colon > last_slash:
        tag = s[last_colon + 1 :].strip()
        name = s[:last_colon].strip()
    else:
        tag = "latest"
        name = s

    # registry vs repo
    parts = name.split("/", 1)
    if len(parts) == 1:
        registry = "docker.io"
        repo = f"library/{parts[0]}"
    else:
        first, rest = parts[0], parts[1]
        if "." in first or ":" in first or first == "localhost":
            registry = first
            repo = rest
        else:
            registry = "docker.io"
            repo = name

    return registry, repo, tag


def normalize_image(raw: str) -> ImageRef:
    registry, repo, tag = _split_image(raw)
    return ImageRef(
        raw=raw,
        registry=registry,
        repo=repo,
        tag=tag,
        normalized=f"{registry}/{repo}:{tag}",
    )


# ----------------------------
# Compose discovery + extraction
# ----------------------------

IMAGE_LINE_RE = re.compile(r"^\s*image\s*:\s*(.+?)\s*$")

def find_compose_files(root: str, pattern: str) -> List[str]:
    full_pat = os.path.join(root, pattern)
    files = glob.glob(full_pat, recursive=True)
    return sorted([f for f in files if os.path.isfile(f)])


def extract_images_from_compose_yaml(path: str) -> Set[str]:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        content = f.read()

    # Prefer PyYAML if available
    try:
        import yaml  # type: ignore
        docs = list(yaml.safe_load_all(content))
        out: Set[str] = set()
        for doc in docs:
            if not isinstance(doc, dict):
                continue
            services = doc.get("services")
            if not isinstance(services, dict):
                continue
            for _, svc in services.items():
                if isinstance(svc, dict):
                    img = svc.get("image")
                    if isinstance(img, str) and img.strip():
                        out.add(img.strip())
        if out:
            return out
    except Exception:
        pass

    # Regex fallback
    out = set()
    for line in content.splitlines():
        m = IMAGE_LINE_RE.match(line)
        if m:
            out.add(m.group(1).strip().strip('"').strip("'"))
    return out


# ----------------------------
# Docker Hub: list tags
# ----------------------------

def _http_json(url: str, timeout: int = 25) -> dict:
    req = urllib.request.Request(url, headers={"User-Agent": "compose-image-version-check/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8", errors="replace"))


def dockerhub_list_tags(repo: str, page_size: int = 100) -> List[Tuple[str, Optional[str]]]:
    """
    Returns list of (tag_name, last_updated) for Docker Hub public repos.
    """
    tags: List[Tuple[str, Optional[str]]] = []
    url = f"https://registry.hub.docker.com/v2/repositories/{repo}/tags?page_size={page_size}"
    while url:
        j = _http_json(url)
        results = j.get("results", [])
        if isinstance(results, list):
            for r in results:
                if isinstance(r, dict) and isinstance(r.get("name"), str):
                    tags.append((r["name"], r.get("last_updated")))
        url = j.get("next")
    return tags


# ----------------------------
# Version heuristics
# ----------------------------

SEMVER_RE = re.compile(r"^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?$")

def split_suffix(tag: str) -> Tuple[str, Optional[str]]:
    """
    Split '2.7-alpine' -> ('2.7', 'alpine')
    Split 'v1.7.0' -> ('v1.7.0', None)
    """
    if "-" in tag and not tag.startswith("sha256:"):
        base, suffix = tag.split("-", 1)
        return base, suffix
    return tag, None


def parse_semverish(s: str) -> Optional[Tuple[int, int, int, bool]]:
    """
    Parse v?MAJOR(.MINOR)?(.PATCH)? and return (maj, min, pat, had_v_prefix)
    Missing parts are treated as -1 for matching logic, but for sorting missing => 0.
    """
    m = SEMVER_RE.match(s)
    if not m:
        return None
    had_v = s.startswith("v")
    maj = int(m.group(1))
    minor = int(m.group(2)) if m.group(2) is not None else -1
    patch = int(m.group(3)) if m.group(3) is not None else -1
    return maj, minor, patch, had_v


def semver_sort_key(v: Tuple[int, int, int, bool]) -> Tuple[int, int, int]:
    maj, minor, patch, _ = v
    return (maj, max(minor, 0), max(patch, 0))


def choose_newer_tag(old_tag: str, all_tags: List[str]) -> Tuple[Optional[str], str]:
    """
    Returns (new_tag, note).

    new_tag is the chosen "latest" relative to old_tag, using heuristics:
      - Keeps suffix (e.g. alpine) if old_tag has it
      - If old is X.Y.Z -> prefer newest X.Y.* (then X.*)
      - If old is X.Y -> prefer newest X.Y.* (then X.*)
      - If old is X -> prefer newest X.* (or X itself if that's how tags are)
    """
    if old_tag in ("latest", "stable"):
        return None, f"'{old_tag}' is not a version tag"

    old_base, old_suffix = split_suffix(old_tag)
    old_v = parse_semverish(old_base)
    if not old_v:
        return None, "tag not semver-like; no safe upgrade suggestion"

    old_maj, old_min, _old_pat, _ = old_v

    # Filter tags: same suffix behavior
    candidates: List[Tuple[str, Tuple[int, int, int, bool]]] = []
    for t in all_tags:
        b, sfx = split_suffix(t)
        if old_suffix != sfx:
            continue
        pv = parse_semverish(b)
        if not pv:
            continue
        candidates.append((t, pv))

    if not candidates:
        return None, "no semver-like candidate tags found"

    # Prefer: same major+minor (if old has minor), else same major
    preferred: List[Tuple[str, Tuple[int, int, int, bool]]] = []
    fallback: List[Tuple[str, Tuple[int, int, int, bool]]] = []

    for t, pv in candidates:
        maj, minor, _patch, _ = pv
        if maj != old_maj:
            continue
        if old_min >= 0:
            if minor == old_min:
                preferred.append((t, pv))
            else:
                fallback.append((t, pv))
        else:
            preferred.append((t, pv))

    pool = preferred if preferred else fallback
    if not pool:
        return None, "no newer tag found in same major"

    # Pick max by semver key
    pool_sorted = sorted(pool, key=lambda x: semver_sort_key(x[1]))
    best_tag, best_v = pool_sorted[-1]

    # Only an upgrade if actually newer
    if semver_sort_key(best_v) <= semver_sort_key(old_v):
        return None, "already at newest matching tag"

    return best_tag, "newer version available"


# ----------------------------
# Main
# ----------------------------

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".", help="Root directory to search")
    ap.add_argument("--glob", default="**/docker-compose*.yml", help="Glob pattern under root")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    files = find_compose_files(root, args.glob)
    if not files:
        print(f"No compose files found under {root} matching {args.glob}", file=sys.stderr)
        return 2

    usage: Dict[str, Set[str]] = {}  # image_raw -> set(relpaths)
    for f in files:
        imgs = extract_images_from_compose_yaml(f)
        for img in imgs:
            usage.setdefault(img, set()).add(os.path.relpath(f, root))

    refs = [normalize_image(raw) for raw in sorted(usage.keys())]

    print(f"Root: {root}")
    print(f"Compose files: {len(files)}  |  Unique images: {len(refs)}\n")

    print(f"{'STATUS':<10} {'REGISTRY':<10} {'IMAGE':<40} {'OLD':<16} {'NEW':<16} {'NOTE'}")
    print("-" * 115)

    # Cache tag lists per repo
    hub_cache: Dict[str, List[str]] = {}

    for ref in refs:
        rel_files = ", ".join(sorted(usage[ref.raw]))

        new_tag: Optional[str] = None
        note: str = "N/A"

        status = "UNSUPPORTED"
        color = C.YELLOW

        if ref.registry == "docker.io":
            try:
                if ref.repo not in hub_cache:
                    tag_rows = dockerhub_list_tags(ref.repo)
                    hub_cache[ref.repo] = [t for (t, _) in tag_rows]

                new_tag, note = choose_newer_tag(ref.tag, hub_cache[ref.repo])

                if ref.tag in ("latest", "stable"):
                    status = "FLOATING"
                    color = C.YELLOW
                elif new_tag:
                    status = "UPGRADE"
                    color = C.RED
                else:
                    status = "CURRENT"
                    color = C.GREEN

            except urllib.error.HTTPError as e:
                status = "ERROR"
                color = C.RED
                note = f"Docker Hub HTTP {e.code}"
            except Exception as e:
                status = "ERROR"
                color = C.RED
                note = f"Docker Hub error: {e}"
        else:
            status = "UNSUPPORTED"
            color = C.YELLOW
            note = "non-Docker Hub registry; tag listing not implemented"

        print(
            f"{color}{status:<10}{C.RESET} "
            f"{ref.registry:<10} {ref.repo:<40} {ref.tag:<16} {(new_tag or '-'): <16} {note}"
        )
        print(f"{'':<10} {'used in:':<40} {rel_files}\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
