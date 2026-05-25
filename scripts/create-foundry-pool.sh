#!/usr/bin/env bash
set -euo pipefail

# Multi-subscription Azure Foundry pool provisioning script.
# Creates N sets of (subscription + resource group + Foundry resource + Claude/GPT deployments).
# Validate API versions, model IDs, Marketplace offers, quota grants, and regions in the target tenant.

# ---------- Defaults (overridable by CLI args or env vars) ----------

POOL_PREFIX="${POOL_PREFIX:-llmpool}"
LOCATION="${LOCATION:-eastus2}"
SUBSCRIPTION_COUNT="${SUBSCRIPTION_COUNT:-10}"
BATCH_SUBSCRIPTION_COUNT="${BATCH_SUBSCRIPTION_COUNT:-5}"
WORKLOAD="${WORKLOAD:-Production}"
BILLING_SCOPE="${BILLING_SCOPE:-}"
MANAGEMENT_GROUP_ID="${MANAGEMENT_GROUP_ID:-}"
DEPLOY_GPT_MODELS="${DEPLOY_GPT_MODELS:-true}"
DEPLOY_CLAUDE_MODELS="${DEPLOY_CLAUDE_MODELS:-true}"
DEPLOY_BATCH="${DEPLOY_BATCH:-true}"
OUT_DIR="${OUT_DIR:-./generated}"
DRY_RUN="${DRY_RUN:-false}"

CLAUDE_MODELS=("claude-opus-4-7" "claude-sonnet-4-6" "claude-haiku-4-5")
GPT_MODELS=("gpt-4o" "gpt-4o-mini")
BATCH_CLAUDE_MODELS=("claude-haiku-4-5")
BATCH_GPT_MODELS=("gpt-4o-mini")

# ---------- CLI argument parsing ----------

usage() {
  cat <<EOF >&2
Usage: $(basename "$0") [OPTIONS]

Provision a multi-subscription Azure Foundry pool with Claude and GPT endpoints.

Options:
  -p, --prefix PREFIX         Naming prefix for all resources (default: \$POOL_PREFIX or "llmpool")
  -n, --count N               Number of interactive subscription sets to create (default: 10)
  -b, --batch-count N         Number of batch subscription sets to create (default: 5)
  -l, --location LOCATION     Azure region (default: eastus2)
  -s, --billing-scope SCOPE   EA/MCA billing scope (required, or set \$BILLING_SCOPE)
  -m, --mgmt-group ID         Management group to move subscriptions into (optional)
  -o, --output DIR            Output directory for generated files (default: ./generated)
      --no-gpt                Skip GPT model deployments
      --no-claude             Skip Claude model deployments
      --no-batch              Skip batch pool creation
      --dry-run               Print actions without executing
  -h, --help                  Show this help

Environment variables (lower priority than CLI args):
  POOL_PREFIX, LOCATION, SUBSCRIPTION_COUNT, BATCH_SUBSCRIPTION_COUNT,
  BILLING_SCOPE, MANAGEMENT_GROUP_ID, DEPLOY_GPT_MODELS, DEPLOY_CLAUDE_MODELS,
  DEPLOY_BATCH, OUT_DIR, DRY_RUN

Examples:
  # Create 3 interactive sets with prefix "teamA"
  $(basename "$0") --prefix teamA --count 3 --billing-scope "/billingAccounts/.../invoiceSections/..."

  # Create 5 interactive + 2 batch sets in westus3
  $(basename "$0") -p prod -n 5 -b 2 -l westus3 -s "\$BILLING_SCOPE"
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--prefix)         POOL_PREFIX="$2"; shift 2 ;;
    -n|--count)          SUBSCRIPTION_COUNT="$2"; shift 2 ;;
    -b|--batch-count)    BATCH_SUBSCRIPTION_COUNT="$2"; shift 2 ;;
    -l|--location)       LOCATION="$2"; shift 2 ;;
    -s|--billing-scope)  BILLING_SCOPE="$2"; shift 2 ;;
    -m|--mgmt-group)     MANAGEMENT_GROUP_ID="$2"; shift 2 ;;
    -o|--output)         OUT_DIR="$2"; shift 2 ;;
    --no-gpt)            DEPLOY_GPT_MODELS="false"; shift ;;
    --no-claude)         DEPLOY_CLAUDE_MODELS="false"; shift ;;
    --no-batch)          DEPLOY_BATCH="false"; shift ;;
    --dry-run)           DRY_RUN="true"; shift ;;
    -h|--help)           usage ;;
    *)                   echo "Unknown option: $1" >&2; usage ;;
  esac
done

BATCH_POOL_PREFIX="${POOL_PREFIX}-batch"

# ---------- Helpers ----------

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: Missing required command: $1" >&2
    exit 1
  fi
}

require_env() {
  if [[ -z "${!1:-}" ]]; then
    echo "ERROR: Missing required value: $1 (set via CLI arg or env var)" >&2
    exit 1
  fi
}

log() {
  echo "[$(date '+%H:%M:%S')] $*" >&2
}

az_cmd() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] az $*" >&2
    return 0
  fi
  az "$@" --only-show-errors
}

az_rest_cmd() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] az rest $*" >&2
    return 0
  fi
  az rest --only-show-errors "$@"
}

# ---------- Subscription management ----------

create_subscription_alias() {
  local index="$1"
  local prefix="$2"
  local role="$3"
  local alias_name="${prefix}-sub-${index}"
  local display_name="${prefix}-foundry-${role}-${index}"

  local body
  body=$(cat <<JSON
{
  "properties": {
    "billingScope": "${BILLING_SCOPE}",
    "displayName": "${display_name}",
    "workLoad": "${WORKLOAD}"
  }
}
JSON
)

  log "Creating subscription alias: $alias_name"
  az_rest_cmd --method put \
    --url "https://management.azure.com/providers/Microsoft.Subscription/aliases/${alias_name}?api-version=2021-10-01" \
    --body "$body" >/dev/null

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "dry-run-sub-id-${index}"
    return 0
  fi

  wait_for_subscription_alias "$alias_name"
}

wait_for_subscription_alias() {
  local alias_name="$1"
  local state=""

  for _ in $(seq 1 60); do
    state="$(az rest --only-show-errors --method get \
      --url "https://management.azure.com/providers/Microsoft.Subscription/aliases/${alias_name}?api-version=2021-10-01" \
      --query "properties.provisioningState" -o tsv 2>/dev/null || true)"

    if [[ "$state" == "Succeeded" ]]; then
      az rest --only-show-errors --method get \
        --url "https://management.azure.com/providers/Microsoft.Subscription/aliases/${alias_name}?api-version=2021-10-01" \
        --query "properties.subscriptionId" -o tsv
      return 0
    fi

    if [[ "$state" == "Failed" || "$state" == "Canceled" ]]; then
      echo "ERROR: Subscription alias $alias_name reached state: $state" >&2
      return 1
    fi

    log "Waiting for $alias_name (state: ${state:-unknown})..."
    sleep 20
  done

  echo "ERROR: Timed out waiting for subscription alias $alias_name" >&2
  return 1
}

move_to_management_group() {
  local subscription_id="$1"
  if [[ -z "$MANAGEMENT_GROUP_ID" ]]; then
    return 0
  fi
  log "Moving $subscription_id to management group $MANAGEMENT_GROUP_ID"
  az_cmd account management-group subscription add \
    --name "$MANAGEMENT_GROUP_ID" \
    --subscription "$subscription_id"
}

# ---------- Provider registration ----------

register_providers() {
  local subscription_id="$1"
  az_cmd account set --subscription "$subscription_id"

  local providers=(
    "Microsoft.CognitiveServices"
    "Microsoft.MachineLearningServices"
    "Microsoft.SaaS"
    "Microsoft.MarketplaceOrdering"
    "Microsoft.KeyVault"
    "Microsoft.ContainerService"
    "Microsoft.OperationalInsights"
  )

  for provider in "${providers[@]}"; do
    log "Registering $provider in subscription $subscription_id"
    az_cmd provider register --namespace "$provider" --wait
  done
}

# ---------- Foundry resource creation ----------

create_foundry_resources() {
  local index="$1"
  local subscription_id="$2"
  local prefix="$3"
  local role="$4"

  local suffix
  suffix="$(printf "%02d" "$index")"
  local resource_group="rg-${prefix}-${suffix}"
  local account_name="${prefix}-foundry-${suffix}"
  local keyvault_name="${prefix}-kv-${suffix}"

  az_cmd account set --subscription "$subscription_id"

  log "Creating resource group: $resource_group"
  az_cmd group create \
    --name "$resource_group" \
    --location "$LOCATION" \
    --tags workload=llm-api-pool pool="$prefix" pool_role="$role" \
    --output none

  log "Creating Key Vault: $keyvault_name"
  az_cmd keyvault create \
    --name "$keyvault_name" \
    --resource-group "$resource_group" \
    --location "$LOCATION" \
    --enable-rbac-authorization true \
    --tags workload=llm-api-pool pool="$prefix" pool_role="$role" \
    --output none

  log "Creating Foundry resource: $account_name"
  az_cmd cognitiveservices account create \
    --name "$account_name" \
    --resource-group "$resource_group" \
    --location "$LOCATION" \
    --kind AIServices \
    --sku S0 \
    --custom-domain "$account_name" \
    --tags workload=llm-api-pool pool="$prefix" pool_role="$role" \
    --output none

  local endpoint=""
  if [[ "$DRY_RUN" != "true" ]]; then
    endpoint="$(az cognitiveservices account show \
      --name "$account_name" \
      --resource-group "$resource_group" \
      --query properties.endpoint -o tsv --only-show-errors)"
  else
    endpoint="https://${account_name}.cognitiveservices.azure.com/"
  fi

  # Deploy models based on pool role
  local claude_list=("${CLAUDE_MODELS[@]}")
  local gpt_list=("${GPT_MODELS[@]}")
  if [[ "$role" == "batch" ]]; then
    claude_list=("${BATCH_CLAUDE_MODELS[@]}")
    gpt_list=("${BATCH_GPT_MODELS[@]}")
  fi

  if [[ "$DEPLOY_CLAUDE_MODELS" == "true" ]]; then
    for model_name in "${claude_list[@]}"; do
      local capacity
      case "$model_name" in
        claude-opus-4-7)    capacity=2000 ;;
        claude-sonnet-4-6)  capacity=4000 ;;
        claude-haiku-4-5)   capacity=4000 ;;
        *)                  capacity=2000 ;;
      esac
      deploy_model "$resource_group" "$account_name" "${model_name}" "${model_name}" "Anthropic" "GlobalStandard" "$capacity"
    done
  fi

  if [[ "$DEPLOY_GPT_MODELS" == "true" ]]; then
    for model_name in "${gpt_list[@]}"; do
      local deploy_name="${model_name//./-}"
      local capacity=10000
      deploy_model "$resource_group" "$account_name" "${deploy_name}" "${model_name}" "OpenAI" "GlobalStandard" "$capacity"
    done
  fi

  # Append to inventory
  printf "%s,%s,%s,%s,%s,%s\n" \
    "$role" "$subscription_id" "$resource_group" "$account_name" "$endpoint" "$keyvault_name" \
    >> "${OUT_DIR}/foundry-endpoints.csv"
}

deploy_model() {
  local resource_group="$1"
  local account_name="$2"
  local deployment_name="$3"
  local model_name="$4"
  local model_format="$5"
  local sku_name="$6"
  local sku_capacity="$7"

  log "Deploying model: $deployment_name ($model_name, format=$model_format) on $account_name"
  az_cmd cognitiveservices account deployment create \
    --name "$account_name" \
    --resource-group "$resource_group" \
    --deployment-name "$deployment_name" \
    --model-name "$model_name" \
    --model-version "auto" \
    --model-format "$model_format" \
    --sku-name "$sku_name" \
    --sku-capacity "$sku_capacity" \
    --output none || {
      log "WARNING: Failed to deploy $deployment_name on $account_name (may require Marketplace acceptance or quota)"
      return 0
    }
}

# ---------- Main ----------

main() {
  require_command az
  require_env BILLING_SCOPE

  log "Validating Azure CLI login..."
  az account show --output none --only-show-errors

  log "=== Foundry Pool Provisioning ==="
  log "Prefix:              $POOL_PREFIX"
  log "Location:            $LOCATION"
  log "Interactive sets:    $SUBSCRIPTION_COUNT"
  log "Batch sets:          $BATCH_SUBSCRIPTION_COUNT"
  log "Deploy Claude:       $DEPLOY_CLAUDE_MODELS"
  log "Deploy GPT:          $DEPLOY_GPT_MODELS"
  log "Deploy batch pool:   $DEPLOY_BATCH"
  log "Dry run:             $DRY_RUN"
  log "Output dir:          $OUT_DIR"
  log "================================="

  mkdir -p "$OUT_DIR"
  printf "pool_role,subscription_id,resource_group,foundry_resource,endpoint,key_vault\n" \
    > "${OUT_DIR}/foundry-endpoints.csv"

  local sub_id

  # Interactive pool
  for index in $(seq 1 "$SUBSCRIPTION_COUNT"); do
    log "--- Interactive set $index/$SUBSCRIPTION_COUNT ---"
    sub_id="$(create_subscription_alias "$index" "$POOL_PREFIX" "interactive")"
    log "Subscription ready: $sub_id"
    move_to_management_group "$sub_id"
    register_providers "$sub_id"
    create_foundry_resources "$index" "$sub_id" "$POOL_PREFIX" "interactive"
  done

  # Batch pool
  if [[ "$DEPLOY_BATCH" == "true" && "$BATCH_SUBSCRIPTION_COUNT" -gt 0 ]]; then
    for index in $(seq 1 "$BATCH_SUBSCRIPTION_COUNT"); do
      log "--- Batch set $index/$BATCH_SUBSCRIPTION_COUNT ---"
      sub_id="$(create_subscription_alias "$index" "$BATCH_POOL_PREFIX" "batch")"
      log "Subscription ready: $sub_id"
      move_to_management_group "$sub_id"
      register_providers "$sub_id"
      create_foundry_resources "$index" "$sub_id" "$BATCH_POOL_PREFIX" "batch"
    done
  fi

  log "=== Provisioning complete ==="
  log "Endpoint inventory: ${OUT_DIR}/foundry-endpoints.csv"
  if [[ -f "${OUT_DIR}/foundry-endpoints.csv" ]]; then
    log "Summary:"
    wc -l < "${OUT_DIR}/foundry-endpoints.csv" | xargs -I{} echo "  {} entries (including header)" >&2
  fi
}

main "$@"
