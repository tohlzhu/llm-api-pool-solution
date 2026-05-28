#!/usr/bin/env bash
set -euo pipefail

# test-endpoints.sh — Test connectivity for Foundry model endpoints.
# Reads foundry-endpoints.csv and sends a minimal request to each endpoint via curl + key.

# ---------- Defaults ----------

INPUT_FILE="${1:-./generated/foundry-endpoints.csv}"
MAX_TOKENS="${MAX_TOKENS:-50}"
TIMEOUT="${TIMEOUT:-30}"
VERBOSE="${VERBOSE:-false}"

# ---------- CLI ----------

usage() {
  cat <<EOF >&2
Usage: $(basename "$0") [OPTIONS] [INVENTORY_CSV]

Test connectivity for Foundry model endpoints.

Arguments:
  INVENTORY_CSV   Path to foundry-endpoints.csv (default: ./generated/foundry-endpoints.csv)

Options:
  -i, --input FILE    Input CSV file (alternative to positional arg)
      --verbose       Show full response body
  -h, --help          Show this help

Environment variables:
  MAX_TOKENS    Max tokens for test request (default: 50)
  TIMEOUT       Curl timeout in seconds (default: 30)
  VERBOSE       Show full response body (default: false)

Input CSV format (from deploy-models.sh):
  model_endpoint, model_name, access_key

Examples:
  $(basename "$0")
  $(basename "$0") ./generated/foundry-endpoints.csv
  VERBOSE=true $(basename "$0")
EOF
  exit 1
}

# Handle options before positional
for arg in "$@"; do
  case "$arg" in
    -h|--help)    usage ;;
    --verbose)    VERBOSE="true" ;;
    -i)           ;; # handled below
  esac
done

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input)   INPUT_FILE="$2"; shift 2 ;;
    --verbose)    VERBOSE="true"; shift ;;
    -h|--help)    usage ;;
    *)
      if [[ -f "$1" ]]; then
        INPUT_FILE="$1"
      fi
      shift
      ;;
  esac
done

if [[ ! -f "$INPUT_FILE" ]]; then
  echo "ERROR: Input file not found: $INPUT_FILE" >&2
  echo "Run deploy-models.sh first to generate the endpoint inventory." >&2
  exit 1
fi

# ---------- Helpers ----------

log() {
  echo "[$(date '+%H:%M:%S')] $*" >&2
}

is_claude_model() {
  [[ "$1" == claude-* ]]
}

is_deepseek_model() {
  [[ "$1" == DeepSeek-* || "$1" == deepseek-* ]]
}

# ---------- Test functions ----------

test_openai_compatible() {
  local endpoint="$1"
  local model_name="$2"
  local api_key="$3"

  local base_url="${endpoint%/}"
  # For OpenAI-compatible endpoints, the endpoint already includes /openai/deployments/model_name
  # We need to use the chat completions path
  local url="${base_url}/chat/completions?api-version=2024-12-01-preview"

  local response
  response="$(curl -s -w "\n%{http_code}" \
    --max-time "$TIMEOUT" \
    "$url" \
    -H "api-key: ${api_key}" \
    -H "Content-Type: application/json" \
    -d "{
      \"messages\": [{\"role\": \"user\", \"content\": \"Say hello in one word.\"}],
      \"max_tokens\": ${MAX_TOKENS}
    }" 2>/dev/null)" || {
    echo "  FAIL: Connection error for $model_name"
    return 1
  }

  local http_code
  http_code="$(echo "$response" | tail -1)"
  local body
  body="$(echo "$response" | sed '$d')"

  if [[ "$http_code" == "200" ]]; then
    echo "  PASS: $model_name (HTTP $http_code)"
    if [[ "$VERBOSE" == "true" ]]; then
      echo "  Response: $body"
    fi
    return 0
  else
    echo "  FAIL: $model_name (HTTP $http_code)"
    if [[ "$VERBOSE" == "true" ]]; then
      echo "  Response: $body"
    fi
    return 1
  fi
}

test_claude_native() {
  local endpoint="$1"
  local model_name="$2"
  local api_key="$3"

  # Extract base URL from the full deployment endpoint path
  # endpoint is like: https://fdry-xxx.cognitiveservices.azure.com/openai/deployments/claude-sonnet-4-6
  local base_url
  base_url="$(echo "$endpoint" | sed 's|/openai/deployments/.*||')"
  local url="${base_url}/anthropic/v1/messages"

  local response
  response="$(curl -s -w "\n%{http_code}" \
    --max-time "$TIMEOUT" \
    "$url" \
    -H "api-key: ${api_key}" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"${model_name}\",
      \"messages\": [{\"role\": \"user\", \"content\": \"Say hello in one word.\"}],
      \"max_tokens\": ${MAX_TOKENS}
    }" 2>/dev/null)" || {
    echo "  FAIL: Connection error for $model_name [native Anthropic API]"
    return 1
  }

  local http_code
  http_code="$(echo "$response" | tail -1)"
  local body
  body="$(echo "$response" | sed '$d')"

  if [[ "$http_code" == "200" ]]; then
    echo "  PASS: $model_name [native Anthropic API] (HTTP $http_code)"
    if [[ "$VERBOSE" == "true" ]]; then
      echo "  Response: $body"
    fi
    return 0
  else
    echo "  FAIL: $model_name [native Anthropic API] (HTTP $http_code)"
    if [[ "$VERBOSE" == "true" ]]; then
      echo "  Response: $body"
    fi
    return 1
  fi
}

# ---------- Main ----------

main() {
  log "Testing endpoints from: $INPUT_FILE"
  echo ""

  local total=0
  local passed=0
  local failed=0
  local skipped=0

  while IFS=',' read -r model_endpoint model_name access_key; do
    # Skip header
    if [[ "$model_endpoint" == "model_endpoint" ]]; then
      continue
    fi

    # Trim
    model_endpoint="$(echo "$model_endpoint" | xargs)"
    model_name="$(echo "$model_name" | xargs)"
    access_key="$(echo "$access_key" | xargs)"

    total=$((total + 1))
    echo "[$total] $model_name → $model_endpoint"

    if [[ -z "$access_key" ]]; then
      echo "  SKIP: No access key available"
      skipped=$((skipped + 1))
      continue
    fi

    # Try OpenAI-compatible first
    if test_openai_compatible "$model_endpoint" "$model_name" "$access_key"; then
      passed=$((passed + 1))
    else
      # For Claude models, try native Anthropic API
      if is_claude_model "$model_name"; then
        if test_claude_native "$model_endpoint" "$model_name" "$access_key"; then
          passed=$((passed + 1))
        else
          failed=$((failed + 1))
        fi
      else
        failed=$((failed + 1))
      fi
    fi
    echo ""
  done < "$INPUT_FILE"

  echo "========================================="
  echo "Results: $passed passed, $failed failed, $skipped skipped (total: $total)"
  echo "========================================="

  if [[ "$failed" -gt 0 ]]; then
    exit 1
  fi
}

main
