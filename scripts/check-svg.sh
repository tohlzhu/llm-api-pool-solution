#!/usr/bin/env bash
set -euo pipefail

log() { printf '%s\n' "$*" >&2; }

DEFAULT_FILES=(
  "assets/architecture-overview.svg"
  "assets/architecture-isolation-fallback.svg"
)

require_python() {
  command -v python3 >/dev/null 2>&1 || {
    log "ERROR: python3 is required"
    exit 1
  }
}

check_wellformed() {
  local file="$1"
  python3 - "$file" <<'PY'
import sys
import xml.etree.ElementTree as ET

path = sys.argv[1]
try:
    ET.parse(path)
except ET.ParseError as exc:
    print(f"malformed XML: {exc}", file=sys.stderr)
    sys.exit(1)
PY
}

check_forbidden() {
  local file="$1" rc=0

  if grep -qi '<script' "$file"; then
    log "  FORBIDDEN: <script> element present"
    rc=1
  fi
  if grep -qi '<foreignObject' "$file"; then
    log "  FORBIDDEN: <foreignObject> element present"
    rc=1
  fi
  if grep -qi 'xlink:href\|<image' "$file"; then
    log "  FORBIDDEN: external image or xlink reference present"
    rc=1
  fi
  # Any http(s) URL other than the SVG/xlink namespace declarations.
  if grep -o 'https\?://[^"'"'"' )]*' "$file" \
    | grep -v '^http://www\.w3\.org/2000/svg$' \
    | grep -v '^http://www\.w3\.org/1999/xlink$' \
    | grep -q .; then
    log "  FORBIDDEN: external URL reference present"
    rc=1
  fi
  if grep -qi '@font-face\|@import' "$file"; then
    log "  FORBIDDEN: external font or stylesheet import present"
    rc=1
  fi

  return "$rc"
}

main() {
  require_python

  local files=("$@")
  if [[ ${#files[@]} -eq 0 ]]; then
    files=("${DEFAULT_FILES[@]}")
  fi

  local failed=0
  for file in "${files[@]}"; do
    log "Checking $file"
    if [[ ! -f "$file" ]]; then
      log "  MISSING: $file"
      failed=1
      continue
    fi
    if ! check_wellformed "$file"; then
      log "  FAIL: not well-formed XML"
      failed=1
      continue
    fi
    if ! check_forbidden "$file"; then
      log "  FAIL: forbidden construct"
      failed=1
      continue
    fi
    log "  OK"
  done

  if [[ "$failed" -ne 0 ]]; then
    log "SVG check FAILED"
    exit 1
  fi
  log "SVG check passed"
}

main "$@"
