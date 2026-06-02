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
  subscription_name, model_endpoint, model_name, model_type, access_key

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

is_bearer_token() {
  # Bearer tokens (JWT) are much longer than API keys and contain dots
  [[ ${#1} -gt 100 && "$1" == *"."* ]]
}

get_auth_header() {
  local api_key="$1"
  if is_bearer_token "$api_key"; then
    echo "Authorization: Bearer ${api_key}"
  else
    echo "api-key: ${api_key}"
  fi
}

# ---------- Test functions ----------

test_claude() {
  local endpoint="$1"
  local model_name="$2"
  local api_key="$3"

  local url="${endpoint%/}"

  local response
  response="$(curl -s -w "\n%{http_code}" \
    --max-time "$TIMEOUT" \
    "$url" \
    -H "x-api-key: ${api_key}" \
    -H "anthropic-version: 2023-06-01" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"${model_name}\",
      \"messages\": [{\"role\": \"user\", \"content\": \"Say hello in one word.\"}],
      \"max_tokens\": ${MAX_TOKENS}
    }" 2>/dev/null)" || {
    echo "  FAIL: $model_name (connection error)"
    return 1
  }

  local http_code
  http_code="$(echo "$response" | tail -1)"
  local body
  body="$(echo "$response" | sed '$d')"

  if [[ "$http_code" == "200" ]]; then
    echo "  PASS: $model_name [Anthropic API] (HTTP $http_code)"
    if [[ "$VERBOSE" == "true" ]]; then
      echo "  Response: $body"
    fi
    return 0
  elif echo "$body" | grep -q '"type":"invalid_request_error"'; then
    echo "  PASS: $model_name [Anthropic API] (HTTP $http_code — upstream Anthropic responded)"
    if [[ "$VERBOSE" == "true" ]]; then
      echo "  Response: $body"
    fi
    return 0
  else
    echo "  FAIL: $model_name [Anthropic API] (HTTP $http_code)"
    if [[ "$VERBOSE" == "true" ]]; then
      echo "  Response: $body"
    fi
    return 1
  fi
}

test_openai() {
  local endpoint="$1"
  local model_name="$2"
  local api_key="$3"

  local url="${endpoint%/}/chat/completions?api-version=2024-12-01-preview"

  local auth_header
  auth_header="$(get_auth_header "$api_key")"

  local response
  response="$(curl -s -w "\n%{http_code}" \
    --max-time "$TIMEOUT" \
    "$url" \
    -H "${auth_header}" \
    -H "Content-Type: application/json" \
    -d "{
      \"messages\": [{\"role\": \"user\", \"content\": \"Say hello in one word.\"}],
      \"max_completion_tokens\": ${MAX_TOKENS}
    }" 2>/dev/null)" || {
    echo "  FAIL: $model_name (connection error)"
    return 1
  }

  local http_code
  http_code="$(echo "$response" | tail -1)"
  local body
  body="$(echo "$response" | sed '$d')"

  if [[ "$http_code" == "200" ]]; then
    echo "  PASS: $model_name [OpenAI API] (HTTP $http_code)"
    if [[ "$VERBOSE" == "true" ]]; then
      echo "  Response: $body"
    fi
    return 0
  else
    echo "  FAIL: $model_name [OpenAI API] (HTTP $http_code)"
    if [[ "$VERBOSE" == "true" ]]; then
      echo "  Response: $body"
    fi
    return 1
  fi
}

test_deepseek() {
  local endpoint="$1"
  local model_name="$2"
  local api_key="$3"

  local url="${endpoint%/}"

  local auth_header
  auth_header="$(get_auth_header "$api_key")"

  local response
  response="$(curl -s -w "\n%{http_code}" \
    --max-time "$TIMEOUT" \
    "$url" \
    -H "${auth_header}" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"${model_name}\",
      \"messages\": [{\"role\": \"user\", \"content\": \"Say hello in one word.\"}],
      \"max_tokens\": ${MAX_TOKENS}
    }" 2>/dev/null)" || {
    echo "  FAIL: $model_name (connection error)"
    return 1
  }

  local http_code
  http_code="$(echo "$response" | tail -1)"
  local body
  body="$(echo "$response" | sed '$d')"

  if [[ "$http_code" == "200" ]]; then
    echo "  PASS: $model_name [Model Inference API] (HTTP $http_code)"
    if [[ "$VERBOSE" == "true" ]]; then
      echo "  Response: $body"
    fi
    return 0
  else
    echo "  FAIL: $model_name [Model Inference API] (HTTP $http_code)"
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

  while IFS=',' read -r subscription_name model_endpoint model_name model_type access_key; do
    # Skip header
    if [[ "$subscription_name" == "subscription_name" ]]; then
      continue
    fi

    # Trim
    subscription_name="$(echo "$subscription_name" | xargs)"
    model_endpoint="$(echo "$model_endpoint" | xargs)"
    model_name="$(echo "$model_name" | xargs)"
    model_type="$(echo "$model_type" | xargs)"
    access_key="$(echo "$access_key" | xargs)"

    # Infer model_type from model_name if not present
    if [[ -z "$model_type" ]]; then
      if is_claude_model "$model_name"; then
        model_type="claude"
      elif is_deepseek_model "$model_name"; then
        model_type="deepseek"
      else
        model_type="gpt"
      fi
    fi

    total=$((total + 1))
    echo "[$total] $model_name ($model_type) → $model_endpoint [$subscription_name]"

    if [[ -z "$access_key" ]]; then
      echo "  SKIP: No access key available"
      skipped=$((skipped + 1))
      continue
    fi

    case "$model_type" in
      claude)
        if test_claude "$model_endpoint" "$model_name" "$access_key"; then
          passed=$((passed + 1))
        else
          failed=$((failed + 1))
        fi
        ;;
      gpt)
        if test_openai "$model_endpoint" "$model_name" "$access_key"; then
          passed=$((passed + 1))
        else
          failed=$((failed + 1))
        fi
        ;;
      deepseek)
        if test_deepseek "$model_endpoint" "$model_name" "$access_key"; then
          passed=$((passed + 1))
        else
          failed=$((failed + 1))
        fi
        ;;
      *)
        if test_openai "$model_endpoint" "$model_name" "$access_key"; then
          passed=$((passed + 1))
        else
          failed=$((failed + 1))
        fi
        ;;
    esac
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
