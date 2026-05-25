#!/usr/bin/env bash
set -euo pipefail

# Test connectivity for all Foundry endpoints listed in the inventory CSV.
# Sends a minimal request to each Claude and GPT deployment to verify accessibility.

INVENTORY="${1:-./generated/foundry-endpoints.csv}"
MODEL="${MODEL:-claude-sonnet-4-6}"
MAX_TOKENS="${MAX_TOKENS:-50}"
TIMEOUT="${TIMEOUT:-30}"
VERBOSE="${VERBOSE:-false}"

usage() {
  cat <<EOF >&2
Usage: $(basename "$0") [INVENTORY_CSV] [OPTIONS]

Test connectivity for Foundry endpoints in the inventory file.

Arguments:
  INVENTORY_CSV   Path to foundry-endpoints.csv (default: ./generated/foundry-endpoints.csv)

Environment variables:
  MODEL           Model to test (default: claude-sonnet-4-6)
  MAX_TOKENS      Max tokens for test request (default: 50)
  TIMEOUT         Curl timeout in seconds (default: 30)
  VERBOSE         Show full response body (default: false)

Examples:
  $(basename "$0")
  $(basename "$0") ./generated/foundry-endpoints.csv
  MODEL=claude-haiku-4-5 $(basename "$0")
  VERBOSE=true $(basename "$0")
EOF
  exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
fi

if [[ ! -f "$INVENTORY" ]]; then
  echo "ERROR: Inventory file not found: $INVENTORY" >&2
  echo "Run create-foundry-pool.sh first to generate the inventory." >&2
  exit 1
fi

log() {
  echo "[$(date '+%H:%M:%S')] $*" >&2
}

test_claude_endpoint() {
  local account_name="$1"
  local resource_group="$2"
  local endpoint="$3"
  local model="$4"

  local api_key
  api_key="$(az cognitiveservices account keys list \
    --name "$account_name" \
    --resource-group "$resource_group" \
    --query key1 -o tsv --only-show-errors 2>/dev/null)" || {
    echo "  SKIP: Cannot retrieve key for $account_name"
    return 1
  }

  local base_url="${endpoint%/}"
  local response
  response="$(curl -s -w "\n%{http_code}" \
    --max-time "$TIMEOUT" \
    "${base_url}/openai/deployments/${model}/chat/completions?api-version=2024-12-01-preview" \
    -H "api-key: ${api_key}" \
    -H "Content-Type: application/json" \
    -d "{
      \"messages\": [{\"role\": \"user\", \"content\": \"Say hello in one word.\"}],
      \"max_tokens\": ${MAX_TOKENS}
    }" 2>/dev/null)" || {
    echo "  FAIL: Connection timeout or error for $account_name/$model"
    return 1
  }

  local http_code
  http_code="$(echo "$response" | tail -1)"
  local body
  body="$(echo "$response" | sed '$d')"

  if [[ "$http_code" == "200" ]]; then
    echo "  PASS: $account_name/$model (HTTP $http_code)"
    if [[ "$VERBOSE" == "true" ]]; then
      echo "  Response: $body"
    fi
    return 0
  else
    echo "  FAIL: $account_name/$model (HTTP $http_code)"
    if [[ "$VERBOSE" == "true" ]]; then
      echo "  Response: $body"
    fi
    return 1
  fi
}

test_claude_native_endpoint() {
  local account_name="$1"
  local resource_group="$2"
  local endpoint="$3"
  local model="$4"

  local api_key
  api_key="$(az cognitiveservices account keys list \
    --name "$account_name" \
    --resource-group "$resource_group" \
    --query key1 -o tsv --only-show-errors 2>/dev/null)" || {
    echo "  SKIP: Cannot retrieve key for $account_name"
    return 1
  }

  local base_url="${endpoint%/}"
  local response
  response="$(curl -s -w "\n%{http_code}" \
    --max-time "$TIMEOUT" \
    "${base_url}/anthropic/v1/messages" \
    -H "api-key: ${api_key}" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"${model}\",
      \"messages\": [{\"role\": \"user\", \"content\": \"Say hello in one word.\"}],
      \"max_tokens\": ${MAX_TOKENS}
    }" 2>/dev/null)" || {
    echo "  FAIL: Connection timeout or error for $account_name/$model (native)"
    return 1
  }

  local http_code
  http_code="$(echo "$response" | tail -1)"
  local body
  body="$(echo "$response" | sed '$d')"

  if [[ "$http_code" == "200" ]]; then
    echo "  PASS: $account_name/$model [native Anthropic API] (HTTP $http_code)"
    if [[ "$VERBOSE" == "true" ]]; then
      echo "  Response: $body"
    fi
    return 0
  else
    echo "  FAIL: $account_name/$model [native Anthropic API] (HTTP $http_code)"
    if [[ "$VERBOSE" == "true" ]]; then
      echo "  Response: $body"
    fi
    return 1
  fi
}

# ---------- Main ----------

main() {
  log "Testing endpoints from: $INVENTORY"
  log "Test model: $MODEL"
  echo ""

  local total=0
  local passed=0
  local failed=0
  local skipped=0

  while IFS=',' read -r pool_role subscription_id resource_group foundry_resource endpoint key_vault; do
    # Skip header
    if [[ "$pool_role" == "pool_role" ]]; then
      continue
    fi

    total=$((total + 1))
    echo "[$total] $foundry_resource ($pool_role, sub=$subscription_id)"

    # Set subscription context
    az account set --subscription "$subscription_id" --only-show-errors 2>/dev/null || {
      echo "  SKIP: Cannot switch to subscription $subscription_id"
      skipped=$((skipped + 1))
      continue
    }

    # Test with OpenAI-compatible endpoint
    if test_claude_endpoint "$foundry_resource" "$resource_group" "$endpoint" "$MODEL"; then
      passed=$((passed + 1))
    else
      # Fallback: try native Anthropic API path for Claude models
      if [[ "$MODEL" == claude-* ]]; then
        if test_claude_native_endpoint "$foundry_resource" "$resource_group" "$endpoint" "$MODEL"; then
          passed=$((passed + 1))
        else
          failed=$((failed + 1))
        fi
      else
        failed=$((failed + 1))
      fi
    fi

    echo ""
  done < "$INVENTORY"

  echo "========================================="
  echo "Results: $passed passed, $failed failed, $skipped skipped (total: $total)"
  echo "========================================="

  if [[ "$failed" -gt 0 ]]; then
    exit 1
  fi
}

main
