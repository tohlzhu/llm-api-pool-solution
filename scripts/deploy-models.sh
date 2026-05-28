#!/usr/bin/env bash
set -euo pipefail

# deploy-models.sh — Phase 2: Deploy Foundry resources and model endpoints.
# Reads subscriptions.csv (from create-subscriptions.sh) and deploys models
# based on the model_type column in the CSV.

# ---------- Defaults ----------

INPUT_FILE="${INPUT_FILE:-./generated/subscriptions.csv}"
OUT_DIR="${OUT_DIR:-./generated}"
DRY_RUN="${DRY_RUN:-false}"
TPM_OVERRIDE="${TPM_OVERRIDE:-}"

ANTHROPIC_API_VERSION="${ANTHROPIC_API_VERSION:-2025-10-01-preview}"

# ---------- Model definitions ----------
# Format: model_name|version (comma-separated per type)

CLAUDE_MODELS="claude-opus-4-7|1,claude-sonnet-4-6|1,claude-haiku-4-5|20251001"
GPT_MODELS="gpt-5.5|2026-04-24,gpt-5.4|2026-03-05,gpt-5.4-mini|2026-03-17,gpt-5.4-nano|2026-03-17"
DEEPSEEK_MODELS="DeepSeek-V4-Pro|2026-04-23,DeepSeek-V4-Flash|2026-04-23"

# Default TPM per model (used when --tpm not specified)
declare -A DEFAULT_TPM=(
  [claude-opus-4-7]=2000000
  [claude-sonnet-4-6]=4000000
  [claude-haiku-4-5]=4000000
  [gpt-5.5]=10000000
  [gpt-5.4]=10000000
  [gpt-5.4-mini]=10000000
  [gpt-5.4-nano]=10000000
  [DeepSeek-V4-Pro]=10000000
  [DeepSeek-V4-Flash]=10000000
)

# ---------- CLI argument parsing ----------

usage() {
  cat <<EOF >&2
Usage: $(basename "$0") [OPTIONS]

Deploy Foundry resources and model endpoints from a subscriptions CSV.
Model type is determined from the CSV's model_type column.

Options:
  -i, --input FILE    Input CSV file (default: ./generated/subscriptions.csv)
  -t, --tpm TPM       Override TPM for all models (useful for testing with low quota)
      --dry-run       Print actions without executing
  -h, --help          Show this help

Input CSV format (from create-subscriptions.sh):
  subscription_id, subscription_name, prefix, model_type, location,
  anthropic-org, anthropic-industry, anthropic-country

Output:
  \$OUT_DIR/foundry-endpoints.csv — columns:
    model_endpoint, model_name, access_key
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input)    INPUT_FILE="$2"; shift 2 ;;
    -t|--tpm)      TPM_OVERRIDE="$2"; shift 2 ;;
    --dry-run)     DRY_RUN="true"; shift ;;
    -h|--help)     usage ;;
    *)             echo "Unknown option: $1" >&2; usage ;;
  esac
done

# ---------- Validation ----------

if [[ ! -f "$INPUT_FILE" ]]; then
  echo "ERROR: Input file not found: $INPUT_FILE" >&2
  exit 1
fi

# ---------- Helpers ----------

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: Missing required command: $1" >&2
    exit 1
  fi
}

log() {
  echo "[$(date '+%H:%M:%S')] $*" >&2
}

random_suffix() {
  printf "%04d" $((RANDOM % 10000))
}

get_tpm() {
  local model_name="$1"
  if [[ -n "$TPM_OVERRIDE" ]]; then
    echo "$TPM_OVERRIDE"
  else
    echo "${DEFAULT_TPM[$model_name]:-2000000}"
  fi
}

# ---------- Provider registration ----------

register_providers() {
  local subscription_id="$1"

  local providers=(
    "Microsoft.CognitiveServices"
    "Microsoft.MachineLearningServices"
    "Microsoft.SaaS"
    "Microsoft.MarketplaceOrdering"
  )

  for provider in "${providers[@]}"; do
    local state
    state="$(az provider show --namespace "$provider" --query "registrationState" -o tsv --only-show-errors 2>/dev/null || echo "NotRegistered")"
    if [[ "$state" == "Registered" ]]; then
      log "  $provider: already registered"
    else
      log "  Registering $provider..."
      if [[ "$DRY_RUN" != "true" ]]; then
        az provider register --namespace "$provider" --only-show-errors
        az provider register --namespace "$provider" --wait --only-show-errors 2>/dev/null || true
      else
        echo "[DRY-RUN] az provider register --namespace $provider" >&2
      fi
    fi
  done
}

# ---------- Foundry resource creation ----------

create_foundry_resource() {
  local subscription_id="$1"
  local prefix="$2"
  local model_type="$3"
  local location="$4"

  local resource_group="rg-foundry"
  local suffix
  suffix="$(random_suffix)"
  local account_name="fdry-${prefix}-${model_type}-${suffix}"

  # Create resource group
  log "  Creating resource group: $resource_group (location: $location)"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] az group create --name $resource_group --location $location" >&2
  else
    az group create \
      --name "$resource_group" \
      --location "$location" \
      --tags workload=llm-api-pool prefix="$prefix" model_type="$model_type" \
      --output none --only-show-errors
  fi

  # Purge soft-deleted resource if name collides
  if [[ "$DRY_RUN" != "true" ]]; then
    local deleted_check
    deleted_check="$(az cognitiveservices account list-deleted --only-show-errors \
      --query "[?name=='${account_name}'].name" -o tsv 2>/dev/null || true)"
    if [[ -n "$deleted_check" ]]; then
      log "  Purging soft-deleted resource: $account_name"
      az cognitiveservices account purge \
        --name "$account_name" \
        --resource-group "$resource_group" \
        --location "$location" --only-show-errors 2>/dev/null || true
      sleep 5
    fi
  fi

  # Create Foundry (AIServices) resource
  log "  Creating Foundry resource: $account_name"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] az cognitiveservices account create --name $account_name --kind AIServices --sku S0" >&2
  else
    az cognitiveservices account create \
      --name "$account_name" \
      --resource-group "$resource_group" \
      --location "$location" \
      --kind AIServices \
      --sku S0 \
      --custom-domain "$account_name" \
      --tags workload=llm-api-pool prefix="$prefix" model_type="$model_type" \
      --output none --only-show-errors
  fi

  echo "$account_name"
}

get_endpoint() {
  local account_name="$1"
  local resource_group="$2"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "https://${account_name}.cognitiveservices.azure.com/"
  else
    az cognitiveservices account show \
      --name "$account_name" \
      --resource-group "$resource_group" \
      --query properties.endpoint -o tsv --only-show-errors
  fi
}

get_access_key() {
  local account_name="$1"
  local resource_group="$2"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "dry-run-key-placeholder"
  else
    az cognitiveservices account keys list \
      --name "$account_name" \
      --resource-group "$resource_group" \
      --query key1 -o tsv --only-show-errors 2>/dev/null || echo ""
  fi
}

# ---------- Model deployment ----------

deploy_claude_model() {
  local subscription_id="$1"
  local resource_group="$2"
  local account_name="$3"
  local model_name="$4"
  local model_version="$5"
  local tpm="$6"
  local anthropic_org="$7"
  local anthropic_industry="$8"
  local anthropic_country="$9"

  local sku_capacity=$((tpm / 1000))
  local deployment_name="$model_name"

  log "  Deploying Claude: $deployment_name (version=$model_version, capacity=$sku_capacity)"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] PUT deployment $deployment_name on $account_name" >&2
    return 0
  fi

  local body
  body=$(cat <<JSON
{
  "sku": {"name": "GlobalStandard", "capacity": ${sku_capacity}},
  "properties": {
    "model": {
      "format": "Anthropic",
      "name": "${model_name}",
      "version": "${model_version}"
    },
    "modelProviderData": {
      "organizationName": "${anthropic_org}",
      "industry": "${anthropic_industry}",
      "countryCode": "${anthropic_country}"
    },
    "versionUpgradeOption": "OnceNewDefaultVersionAvailable"
  }
}
JSON
)

  local url="https://management.azure.com/subscriptions/${subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.CognitiveServices/accounts/${account_name}/deployments/${deployment_name}?api-version=${ANTHROPIC_API_VERSION}"

  az rest --only-show-errors --method put --url "$url" --body "$body" --output none 2>&1 || {
    log "  WARNING: Failed to deploy $deployment_name (may require Marketplace acceptance or quota)"
    return 0
  }

  # Wait for async deployment
  log "  Waiting for $deployment_name..."
  local state=""
  for _ in $(seq 1 30); do
    state="$(az rest --only-show-errors --method get --url "$url" \
      --query "properties.provisioningState" -o tsv 2>/dev/null || echo "Unknown")"
    if [[ "$state" == "Succeeded" ]]; then
      log "  $deployment_name: Succeeded"
      return 0
    fi
    if [[ "$state" == "Failed" || "$state" == "Canceled" ]]; then
      log "  WARNING: $deployment_name reached state: $state"
      return 0
    fi
    sleep 10
  done
  log "  WARNING: $deployment_name timed out (state: ${state:-unknown})"
}

deploy_openai_model() {
  local resource_group="$1"
  local account_name="$2"
  local model_name="$3"
  local model_version="$4"
  local tpm="$5"

  local sku_capacity=$((tpm / 1000))
  local deployment_name="${model_name}"

  log "  Deploying GPT: $deployment_name (version=$model_version, capacity=$sku_capacity)"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] az cognitiveservices account deployment create --deployment-name $deployment_name --model-name $model_name" >&2
    return 0
  fi

  az cognitiveservices account deployment create \
    --name "$account_name" \
    --resource-group "$resource_group" \
    --deployment-name "$deployment_name" \
    --model-name "$model_name" \
    --model-version "$model_version" \
    --model-format "OpenAI" \
    --sku-name "GlobalStandard" \
    --sku-capacity "$sku_capacity" \
    --output none --only-show-errors || {
      log "  WARNING: Failed to deploy $deployment_name (may require quota or region)"
      return 0
    }
}

deploy_deepseek_model() {
  local resource_group="$1"
  local account_name="$2"
  local model_name="$3"
  local model_version="$4"
  local tpm="$5"

  local sku_capacity=$((tpm / 1000))
  local deployment_name="${model_name}"

  log "  Deploying DeepSeek: $deployment_name (version=$model_version, capacity=$sku_capacity)"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] az cognitiveservices account deployment create --deployment-name $deployment_name --model-name $model_name" >&2
    return 0
  fi

  az cognitiveservices account deployment create \
    --name "$account_name" \
    --resource-group "$resource_group" \
    --deployment-name "$deployment_name" \
    --model-name "$model_name" \
    --model-version "$model_version" \
    --model-format "DeepSeek" \
    --sku-name "GlobalStandard" \
    --sku-capacity "$sku_capacity" \
    --output none --only-show-errors || {
      log "  WARNING: Failed to deploy $deployment_name (may require quota or region)"
      return 0
    }
}

# ---------- Main ----------

main() {
  require_command az

  log "Validating Azure CLI login..."
  az account show --output none --only-show-errors

  log "=== Model Deployment ==="
  log "Input file:     $INPUT_FILE"
  log "TPM override:   ${TPM_OVERRIDE:-<default per model>}"
  log "Dry run:        $DRY_RUN"
  log "Output dir:     $OUT_DIR"
  log "========================"

  mkdir -p "$OUT_DIR"

  local output_csv="${OUT_DIR}/foundry-endpoints.csv"
  printf "model_endpoint,model_name,access_key\n" > "$output_csv"

  local line_num=0

  while IFS=',' read -r subscription_id subscription_name prefix model_type location anthropic_org anthropic_industry anthropic_country; do
    line_num=$((line_num + 1))
    # Skip header
    if [[ "$line_num" -eq 1 ]]; then
      continue
    fi

    # Trim whitespace
    subscription_id="$(echo "$subscription_id" | xargs)"
    subscription_name="$(echo "$subscription_name" | xargs)"
    prefix="$(echo "$prefix" | xargs)"
    model_type="$(echo "$model_type" | xargs)"
    location="$(echo "$location" | xargs)"
    anthropic_org="$(echo "$anthropic_org" | xargs)"
    anthropic_industry="$(echo "$anthropic_industry" | xargs)"
    anthropic_country="$(echo "$anthropic_country" | xargs)"

    if [[ -z "$subscription_id" || -z "$prefix" || -z "$model_type" ]]; then
      log "WARNING: Skipping line $line_num (missing required fields)"
      continue
    fi

    log "=== Processing: $subscription_name (sub=$subscription_id, type=$model_type) ==="

    # Set subscription context
    if [[ "$DRY_RUN" != "true" ]]; then
      az account set --subscription "$subscription_id" --only-show-errors
    else
      echo "[DRY-RUN] az account set --subscription $subscription_id" >&2
    fi

    # Register providers
    register_providers "$subscription_id"

    # Create Foundry resource
    local account_name
    account_name="$(create_foundry_resource "$subscription_id" "$prefix" "$model_type" "$location")"
    log "  Foundry resource: $account_name"

    local resource_group="rg-foundry"
    local endpoint
    endpoint="$(get_endpoint "$account_name" "$resource_group")"

    # Deploy models based on model_type
    local models_list=""
    case "$model_type" in
      claude)   models_list="$CLAUDE_MODELS" ;;
      gpt)      models_list="$GPT_MODELS" ;;
      deepseek) models_list="$DEEPSEEK_MODELS" ;;
      *)
        log "WARNING: Unknown model_type '$model_type', skipping"
        continue
        ;;
    esac

    IFS=',' read -ra models <<< "$models_list"
    for model_entry in "${models[@]}"; do
      local m_name="${model_entry%%|*}"
      local m_version="${model_entry##*|}"
      local tpm
      tpm="$(get_tpm "$m_name")"

      case "$model_type" in
        claude)
          deploy_claude_model "$subscription_id" "$resource_group" "$account_name" \
            "$m_name" "$m_version" "$tpm" "$anthropic_org" "$anthropic_industry" "$anthropic_country"
          ;;
        gpt)
          deploy_openai_model "$resource_group" "$account_name" "$m_name" "$m_version" "$tpm"
          ;;
        deepseek)
          deploy_deepseek_model "$resource_group" "$account_name" "$m_name" "$m_version" "$tpm"
          ;;
      esac

      # Write endpoint entry
      printf "%s,%s,%s\n" \
        "${endpoint%/}/openai/deployments/${m_name}" "$m_name" "$(get_access_key "$account_name" "$resource_group")" \
        >> "$output_csv"
    done

  done < "$INPUT_FILE"

  log "=== Deployment complete ==="
  log "Endpoint inventory: $output_csv"
  if [[ -f "$output_csv" ]]; then
    local count
    count="$(tail -n +2 "$output_csv" | wc -l)"
    log "  $count model endpoints deployed"
  fi
}

main "$@"
