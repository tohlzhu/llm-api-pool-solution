#!/usr/bin/env bash
set -euo pipefail

# Reference implementation for a multi-subscription Microsoft Foundry model pool.
# Validate API versions, model IDs, Marketplace offers, quota grants, and regions in the target tenant.

POOL_PREFIX="${POOL_PREFIX:-llmapi}"
LOCATION="${LOCATION:-eastus2}"
SUBSCRIPTION_COUNT="${SUBSCRIPTION_COUNT:-10}"
WORKLOAD="${WORKLOAD:-Production}"
BILLING_SCOPE="${BILLING_SCOPE:-}"
MANAGEMENT_GROUP_ID="${MANAGEMENT_GROUP_ID:-}"
DEPLOY_GPT_MODELS="${DEPLOY_GPT_MODELS:-true}"
DEPLOY_PARTNER_MODELS="${DEPLOY_PARTNER_MODELS:-false}"
OUT_DIR="${OUT_DIR:-./generated}"

GPT_MODELS=("gpt-5.5" "gpt-5.4")
CLAUDE_MODELS=("claude-opus-4-7" "claude-sonnet-4-6" "claude-haiku-4-5")

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
}

require_env() {
  local variable_name="$1"
  if [[ -z "${!variable_name:-}" ]]; then
    echo "Missing required environment variable: $variable_name" >&2
    exit 1
  fi
}

az_rest() {
  az rest --only-show-errors "$@"
}

create_subscription_alias() {
  local index="$1"
  local alias_name="${POOL_PREFIX}-sub-${index}"
  local display_name="${POOL_PREFIX}-foundry-${index}"
  local request_body

  request_body="$(cat <<JSON
{
  "properties": {
    "billingScope": "${BILLING_SCOPE}",
    "displayName": "${display_name}",
    "workLoad": "${WORKLOAD}"
  }
}
JSON
)"

  echo "Creating subscription alias $alias_name" >&2
  az_rest --method put \
    --url "https://management.azure.com/providers/Microsoft.Subscription/aliases/${alias_name}?api-version=2021-10-01" \
    --body "$request_body" >/dev/null

  wait_for_subscription_alias "$alias_name"
}

wait_for_subscription_alias() {
  local alias_name="$1"
  local state=""

  for _ in {1..60}; do
    state="$(az_rest --method get \
      --url "https://management.azure.com/providers/Microsoft.Subscription/aliases/${alias_name}?api-version=2021-10-01" \
      --query "properties.provisioningState" -o tsv 2>/dev/null || true)"

    if [[ "$state" == "Succeeded" ]]; then
      az_rest --method get \
        --url "https://management.azure.com/providers/Microsoft.Subscription/aliases/${alias_name}?api-version=2021-10-01" \
        --query "properties.subscriptionId" -o tsv
      return 0
    fi

    if [[ "$state" == "Failed" || "$state" == "Canceled" ]]; then
      echo "Subscription alias $alias_name failed with state $state" >&2
      return 1
    fi

    echo "Waiting for subscription alias $alias_name, current state: ${state:-unknown}" >&2
    sleep 20
  done

  echo "Timed out waiting for subscription alias $alias_name" >&2
  return 1
}

move_subscription_to_management_group() {
  local subscription_id="$1"
  if [[ -z "$MANAGEMENT_GROUP_ID" ]]; then
    return 0
  fi

  az account management-group subscription add \
    --name "$MANAGEMENT_GROUP_ID" \
    --subscription "$subscription_id" >/dev/null
}

register_providers() {
  local subscription_id="$1"
  az account set --subscription "$subscription_id"

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
    echo "Registering provider $provider in $subscription_id" >&2
    az provider register --namespace "$provider" --wait --only-show-errors
  done
}

create_foundry_resources() {
  local index="$1"
  local subscription_id="$2"
  local suffix resource_group account_name keyvault_name endpoint
  suffix="$(printf "%02d" "$index")"
  resource_group="rg-${POOL_PREFIX}-${suffix}"
  account_name="${POOL_PREFIX}-foundry-${suffix}"
  keyvault_name="${POOL_PREFIX}-kv-${suffix}"

  az account set --subscription "$subscription_id"

  az group create --name "$resource_group" --location "$LOCATION" \
    --tags workload=llm-api-pool pool="$POOL_PREFIX" --output none

  az keyvault create --name "$keyvault_name" --resource-group "$resource_group" \
    --location "$LOCATION" --enable-rbac-authorization true \
    --tags workload=llm-api-pool pool="$POOL_PREFIX" --output none

  az cognitiveservices account create \
    --name "$account_name" \
    --resource-group "$resource_group" \
    --location "$LOCATION" \
    --kind AIServices \
    --sku S0 \
    --custom-domain "$account_name" \
    --tags workload=llm-api-pool pool="$POOL_PREFIX" \
    --output none

  endpoint="$(az cognitiveservices account show \
    --name "$account_name" \
    --resource-group "$resource_group" \
    --query properties.endpoint -o tsv)"

  if [[ "$DEPLOY_GPT_MODELS" == "true" ]]; then
    for model_name in "${GPT_MODELS[@]}"; do
      deploy_model "$resource_group" "$account_name" "${model_name//./-}" "$model_name" "OpenAI" "GlobalStandard" 100
    done
  fi

  if [[ "$DEPLOY_PARTNER_MODELS" == "true" ]]; then
    for model_name in "${CLAUDE_MODELS[@]}"; do
      deploy_model "$resource_group" "$account_name" "${model_name//./-}" "$model_name" "Anthropic" "GlobalStandard" 100 || true
    done
  else
    cat <<INFO >&2
Claude partner model deployment is intentionally left as a tenant-specific action.
Confirm Marketplace terms, publisher/offer/plan IDs, supported region, model ID, and Foundry deployment API before setting DEPLOY_PARTNER_MODELS=true.
INFO
  fi

  cat <<CSV >> "${OUT_DIR}/foundry-endpoints.csv"
${subscription_id},${resource_group},${account_name},${endpoint},${keyvault_name}
CSV
}

deploy_model() {
  local resource_group="$1"
  local account_name="$2"
  local deployment_name="$3"
  local model_name="$4"
  local model_format="$5"
  local sku_name="$6"
  local sku_capacity="$7"

  echo "Deploying $deployment_name ($model_name) on $account_name" >&2
  az cognitiveservices account deployment create \
    --name "$account_name" \
    --resource-group "$resource_group" \
    --deployment-name "$deployment_name" \
    --model-name "$model_name" \
    --model-version "auto" \
    --model-format "$model_format" \
    --sku-name "$sku_name" \
    --sku-capacity "$sku_capacity" \
    --output none
}

main() {
  require_command az
  require_env BILLING_SCOPE
  az account show --output none
  mkdir -p "$OUT_DIR"
  printf "subscription_id,resource_group,foundry_resource,endpoint,key_vault\n" > "${OUT_DIR}/foundry-endpoints.csv"

  for index in $(seq 1 "$SUBSCRIPTION_COUNT"); do
    subscription_id="$(create_subscription_alias "$index")"
    echo "Created subscription $subscription_id" >&2
    move_subscription_to_management_group "$subscription_id"
    register_providers "$subscription_id"
    create_foundry_resources "$index" "$subscription_id"
  done

  echo "Endpoint inventory written to ${OUT_DIR}/foundry-endpoints.csv"
}

main "$@"