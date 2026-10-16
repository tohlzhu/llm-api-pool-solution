#!/usr/bin/env bash
set -euo pipefail

# deploy-models.sh — Phase 2: Deploy Foundry resources and model endpoints.
# Reads subscriptions.csv (from create-subscriptions.sh) and deploys models
# based on the model_type column in the CSV.
# Idempotent: reuses existing resource groups, Foundry accounts, projects, and deployments.

# ---------- Defaults ----------

INPUT_FILE="${INPUT_FILE:-./generated/subscriptions.csv}"
OUT_DIR="${OUT_DIR:-./generated}"
DRY_RUN="${DRY_RUN:-false}"
TPM_OVERRIDE="${TPM_OVERRIDE:-}"
FORCE="${FORCE:-false}"

ANTHROPIC_API_VERSION="${ANTHROPIC_API_VERSION:-2025-10-01-preview}"

# ---------- Model definitions ----------
# Format: model_name|version (comma-separated per type)

CLAUDE_MODELS="claude-opus-5-5|2,claude-sonnet-5-5|2,claude-haiku-5-5|2"
GPT_MODELS="gpt-5.6-sol|2026-07-09,gpt-5.6-terra|2026-07-09,gpt-5.6-luna|2026-07-09,gpt-6-astra|2026-09-03,gpt-6-sol|2026-09-22,gpt-6.1-sol|2026-09-29,gpt-6-luna|2026-09-22"
GPT_LUNA_MODELS="gpt-5.6-luna|2026-07-09,gpt-6-luna|2026-09-22"
DEEPSEEK_MODELS="DeepSeek-V4-Pro|2026-04-23,DeepSeek-V4-Flash|2026-04-23"

# Default TPM per model (used when --tpm not specified)
declare -A DEFAULT_TPM=(
  [claude-opus-5-5]=10000000
  [claude-sonnet-5-5]=10000000
  [claude-haiku-5-5]=10000000
  [gpt-5.6-sol]=10000000
  [gpt-5.6-terra]=10000000
  [gpt-5.6-luna]=10000000
  [gpt-6-astra]=10000000
  [gpt-6-sol]=10000000
  [gpt-6.1-sol]=10000000
  [gpt-6-luna]=10000000
  [DeepSeek-V4-Pro]=10000000
  [DeepSeek-V4-Flash]=10000000
)

# ---------- CLI argument parsing ----------

usage() {
  cat <<EOF >&2
Usage: $(basename "$0") [OPTIONS]

Deploy Foundry resources and model endpoints from a subscriptions CSV.
Model type is determined from the CSV's model_type column.
Idempotent: reuses existing resources and skips already-deployed models.

Options:
  -i, --input FILE    Input CSV file (default: ./generated/subscriptions.csv)
  -t, --tpm TPM       Override TPM for all models (useful for testing with low quota)
      --force         Skip confirmation prompt
      --dry-run       Print actions without executing
  -h, --help          Show this help

Input CSV format (from create-subscriptions.sh):
  subscription_id, subscription_name, prefix, model_type, location,
  anthropic-org, anthropic-industry, anthropic-country

Output:
  \$OUT_DIR/foundry-endpoints-<batch>.csv (OUT_DIR defaults to ./generated) — columns:
    subscription_name, model_endpoint, model_name, model_type, access_key

The batch name comes from the input filename:
  subscriptions-code01.csv -> foundry-endpoints-code01.csv
  custom-batch.csv         -> foundry-endpoints-custom-batch.csv
  subscriptions.csv        -> foundry-endpoints.csv (legacy)
Use distinct input basenames and non-overlapping subscriptions for parallel batches.
Existing inventories are regenerated; concurrent writers to the same CSV are rejected.
Requires flock (util-linux). Keep the .lock file; the lock releases on exit.
Run test-endpoints.sh on the matching inventory only after deployment finishes.

Example:
  $(basename "$0") --input ./generated/subscriptions-code01.csv
  scripts/test-endpoints.sh ./generated/foundry-endpoints-code01.csv
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input)    INPUT_FILE="$2"; shift 2 ;;
    -t|--tpm)      TPM_OVERRIDE="$2"; shift 2 ;;
    --force)       FORCE="true"; shift ;;
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

resolve_anthropic_params() {
  local subscription_id="$1"
  local -n _org="$2"
  local -n _industry="$3"
  local -n _country="$4"

  if [[ -n "$_org" && -n "$_industry" && -n "$_country" ]]; then
    return 0
  fi

  local home_tenant
  home_tenant="$(az account show --subscription "$subscription_id" --query "homeTenantId" -o tsv --only-show-errors 2>/dev/null || true)"
  if [[ -z "$home_tenant" ]]; then
    log "  WARNING: Unable to resolve homeTenantId for subscription $subscription_id"
    return 0
  fi

  if [[ -z "$_org" ]]; then
    _org="$(az rest --method get \
      --subscription "$subscription_id" \
      --url "https://management.azure.com/tenants?api-version=2022-12-01" \
      --query "value[?tenantId=='${home_tenant}'].displayName | [0]" -o tsv --only-show-errors 2>/dev/null || true)"
  fi

  if [[ -z "$_country" ]]; then
    _country="$(az rest --method get \
      --subscription "$subscription_id" \
      --url "https://management.azure.com/tenants?api-version=2022-12-01" \
      --query "value[?tenantId=='${home_tenant}'].countryCode | [0]" -o tsv --only-show-errors 2>/dev/null || true)"
  fi

  if [[ -z "$_industry" ]]; then
    _industry="manufacturing"
  fi

  if [[ -z "$_org" || -z "$_country" ]]; then
    log "  WARNING: Could not auto-resolve all Anthropic params from tenant $home_tenant (org=${_org:-<empty>}, country=${_country:-<empty>})"
    log "  Please specify anthropic-org and anthropic-country in the CSV for this subscription"
  else
    log "  Anthropic params (auto-resolved): organizationName=${_org}, industry=${_industry}, countryCode=${_country}"
    if [[ "$_org" == "默认目录" || "$_org" == "Default Directory" || "$_org" =~ ^默认 ]]; then
      log "  WARNING: organizationName='${_org}' appears to be a placeholder, not a legal entity name."
      log "  Consider specifying the actual company name via anthropic-org column in the CSV."
    fi
  fi
}

log() {
  echo "[$(date '+%H:%M:%S')] $*" >&2
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
    state="$(az provider show \
      --namespace "$provider" \
      --subscription "$subscription_id" \
      --query "registrationState" -o tsv --only-show-errors 2>/dev/null || echo "NotRegistered")"
    if [[ "$state" == "Registered" ]]; then
      log "  $provider: already registered"
    else
      log "  Registering $provider..."
      if [[ "$DRY_RUN" != "true" ]]; then
        az provider register \
          --namespace "$provider" \
          --subscription "$subscription_id" \
          --only-show-errors
        az provider register \
          --namespace "$provider" \
          --subscription "$subscription_id" \
          --wait --only-show-errors 2>/dev/null || true
      else
        echo "[DRY-RUN] az provider register --namespace $provider --subscription $subscription_id" >&2
      fi
    fi
  done
}

# ---------- Foundry account and project creation (idempotent) ----------

create_foundry_resource() {
  local subscription_id="$1"
  local subscription_name="$2"
  local prefix="$3"
  local model_type="$4"
  local location="$5"

  local resource_group="rg-foundry"
  local account_name="fdry-${subscription_name}"

  # Create or reuse resource group
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] az group create --name $resource_group --subscription $subscription_id --location $location" >&2
  else
    local rg_exists
    rg_exists="$(az group exists \
      --name "$resource_group" \
      --subscription "$subscription_id" \
      --only-show-errors 2>/dev/null || echo "false")"
    if [[ "$rg_exists" == "true" ]]; then
      log "  Resource group already exists: $resource_group"
    else
      log "  Creating resource group: $resource_group (location: $location)"
      az group create \
        --name "$resource_group" \
        --subscription "$subscription_id" \
        --location "$location" \
        --tags workload=llm-api-pool prefix="$prefix" model_type="$model_type" \
        --output none --only-show-errors
    fi
  fi

  if [[ "$DRY_RUN" != "true" ]]; then
    if az cognitiveservices account show \
      --name "$account_name" \
      --resource-group "$resource_group" \
      --subscription "$subscription_id" \
      --output none --only-show-errors 2>/dev/null; then
      local project_management_enabled
      project_management_enabled="$(az cognitiveservices account show \
        --name "$account_name" \
        --resource-group "$resource_group" \
        --subscription "$subscription_id" \
        --query 'properties.allowProjectManagement' -o tsv --only-show-errors)"
      if [[ "$project_management_enabled" != "true" ]]; then
        echo "ERROR: Foundry resource $account_name does not have project management enabled and cannot host a Foundry project. Recreate it with --allow-project-management true." >&2
        return 1
      fi
      log "  Reusing existing Foundry resource: $account_name"
      echo "$account_name"
      return 0
    fi
  fi

  # Purge soft-deleted resource if name collides
  if [[ "$DRY_RUN" != "true" ]]; then
    local deleted_check
    deleted_check="$(az cognitiveservices account list-deleted \
      --subscription "$subscription_id" --only-show-errors \
      --query "[?name=='${account_name}'].name" -o tsv 2>/dev/null || true)"
    if [[ -n "$deleted_check" ]]; then
      log "  Purging soft-deleted resource: $account_name"
      az cognitiveservices account purge \
        --name "$account_name" \
        --resource-group "$resource_group" \
        --subscription "$subscription_id" \
        --location "$location" --only-show-errors 2>/dev/null || true
      sleep 5
    fi
  fi

  log "  Creating Foundry resource: $account_name"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] az cognitiveservices account create --name $account_name --subscription $subscription_id --kind AIServices --sku S0 --allow-project-management true" >&2
  else
    if ! az cognitiveservices account create \
      --name "$account_name" \
      --resource-group "$resource_group" \
      --subscription "$subscription_id" \
      --location "$location" \
      --kind AIServices \
      --sku S0 \
      --custom-domain "$account_name" \
      --allow-project-management true \
      --assign-identity \
      --tags workload=llm-api-pool prefix="$prefix" model_type="$model_type" \
      --output none --only-show-errors; then
      log "  ERROR: Failed to create Foundry resource $account_name in subscription $subscription_id"
      return 1
    fi
  fi

  # Assign Cognitive Services OpenAI User role to deploying user.
  if [[ "$DRY_RUN" != "true" ]]; then
    local user_id
    user_id="$(az ad signed-in-user show --subscription "$subscription_id" --query id -o tsv --only-show-errors 2>/dev/null || true)"
    if [[ -n "$user_id" ]]; then
      local scope="/subscriptions/${subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.CognitiveServices/accounts/${account_name}"
      az role assignment create \
        --assignee "$user_id" \
        --role "Cognitive Services OpenAI User" \
        --scope "$scope" \
        --subscription "$subscription_id" \
        --only-show-errors --output none 2>/dev/null || true
    fi
  fi

  echo "$account_name"
}

create_foundry_project() {
  local subscription_id="$1"
  local account_name="$2"
  local subscription_name="$3"
  local resource_group="$4"
  local location="$5"
  local project_name="proj-${subscription_name}"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] az cognitiveservices account project create --name $account_name --subscription $subscription_id --project-name $project_name --location $location" >&2
    return 0
  fi

  if az cognitiveservices account project show \
    --name "$account_name" \
    --resource-group "$resource_group" \
    --subscription "$subscription_id" \
    --project-name "$project_name" \
    --output none --only-show-errors 2>/dev/null; then
    log "  Reusing existing Foundry project: $project_name"
    return 0
  fi

  log "  Creating Foundry project: $project_name"
  az cognitiveservices account project create \
    --name "$account_name" \
    --resource-group "$resource_group" \
    --subscription "$subscription_id" \
    --project-name "$project_name" \
    --location "$location" \
    --assign-identity \
    --output none --only-show-errors
}

get_endpoint() {
  local subscription_id="$1"
  local account_name="$2"
  local resource_group="$3"
  local model_type="$4"

  if [[ "$DRY_RUN" == "true" ]]; then
    case "$model_type" in
      claude|deepseek) echo "https://${account_name}.services.ai.azure.com/" ;;
      gpt|gpt-luna)    echo "https://${account_name}.openai.azure.com/" ;;
      *)               echo "https://${account_name}.cognitiveservices.azure.com/" ;;
    esac
    return 0
  fi

  case "$model_type" in
    claude|deepseek)
      az cognitiveservices account show \
        --name "$account_name" \
        --resource-group "$resource_group" \
        --subscription "$subscription_id" \
        --query 'properties.endpoints."AI Foundry API"' -o tsv --only-show-errors
      ;;
    gpt|gpt-luna)
      az cognitiveservices account show \
        --name "$account_name" \
        --resource-group "$resource_group" \
        --subscription "$subscription_id" \
        --query 'properties.endpoints."Azure OpenAI Legacy API - Latest moniker"' -o tsv --only-show-errors
      ;;
    *)
      az cognitiveservices account show \
        --name "$account_name" \
        --resource-group "$resource_group" \
        --subscription "$subscription_id" \
        --query properties.endpoint -o tsv --only-show-errors
      ;;
  esac
}

get_access_key() {
  local subscription_id="$1"
  local account_name="$2"
  local resource_group="$3"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "dry-run-key-placeholder"
    return 0
  fi
  local key=""
  local attempt
  for attempt in 1 2 3 4 5; do
    key="$(az cognitiveservices account keys list \
      --name "$account_name" \
      --resource-group "$resource_group" \
      --subscription "$subscription_id" \
      --query key1 -o tsv --only-show-errors 2>/dev/null || true)"
    if [[ -n "$key" ]]; then
      echo "$key"
      return 0
    fi
    log "  Waiting for access key to become available (attempt $attempt/5)..."
    sleep 5
  done
  log "  WARNING: Could not retrieve API key after retries, falling back to access token"
  az account get-access-token \
    --subscription "$subscription_id" \
    --resource https://cognitiveservices.azure.com \
    --query accessToken -o tsv --only-show-errors 2>/dev/null || echo ""
}

# ---------- Deployment existence check ----------

check_deployment_exists() {
  local subscription_id="$1"
  local resource_group="$2"
  local account_name="$3"
  local deployment_name="$4"

  local state
  state="$(az cognitiveservices account deployment show \
    --name "$account_name" \
    --resource-group "$resource_group" \
    --subscription "$subscription_id" \
    --deployment-name "$deployment_name" \
    --query "properties.provisioningState" -o tsv --only-show-errors 2>/dev/null || true)"

  if [[ -n "$state" ]]; then
    echo "$state"
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

  # Check if deployment already exists
  if [[ "$DRY_RUN" != "true" ]]; then
    local existing_state
    existing_state="$(check_deployment_exists "$subscription_id" "$resource_group" "$account_name" "$deployment_name")"
    if [[ -n "$existing_state" ]]; then
      log "  $deployment_name: already exists (state=$existing_state), skipping"
      return 0
    fi
  fi

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

  az rest --subscription "$subscription_id" --only-show-errors --method put --url "$url" --body "$body" --output none 2>&1 || {
    log "  WARNING: Failed to deploy $deployment_name (may require Marketplace acceptance or quota)"
    return 0
  }

  log "  Waiting for $deployment_name..."
  local state=""
  for _ in $(seq 1 30); do
    state="$(az rest --subscription "$subscription_id" --only-show-errors --method get --url "$url" \
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
  local subscription_id="$1"
  local resource_group="$2"
  local account_name="$3"
  local model_name="$4"
  local model_version="$5"
  local tpm="$6"

  local sku_capacity=$((tpm / 1000))
  local deployment_name="${model_name}"

  # Check if deployment already exists
  if [[ "$DRY_RUN" != "true" ]]; then
    local existing_state
    existing_state="$(check_deployment_exists "$subscription_id" "$resource_group" "$account_name" "$deployment_name")"
    if [[ -n "$existing_state" ]]; then
      log "  $deployment_name: already exists (state=$existing_state), skipping"
      return 0
    fi
  fi

  log "  Deploying GPT: $deployment_name (version=$model_version, capacity=$sku_capacity)"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] az cognitiveservices account deployment create --subscription $subscription_id --deployment-name $deployment_name --model-name $model_name" >&2
    return 0
  fi

  az cognitiveservices account deployment create \
    --name "$account_name" \
    --resource-group "$resource_group" \
    --subscription "$subscription_id" \
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
  local subscription_id="$1"
  local resource_group="$2"
  local account_name="$3"
  local model_name="$4"
  local model_version="$5"
  local tpm="$6"

  local sku_capacity=$((tpm / 1000))
  local deployment_name="${model_name}"

  # Check if deployment already exists
  if [[ "$DRY_RUN" != "true" ]]; then
    local existing_state
    existing_state="$(check_deployment_exists "$subscription_id" "$resource_group" "$account_name" "$deployment_name")"
    if [[ -n "$existing_state" ]]; then
      log "  $deployment_name: already exists (state=$existing_state), skipping"
      return 0
    fi
  fi

  log "  Deploying DeepSeek: $deployment_name (version=$model_version, capacity=$sku_capacity)"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] az cognitiveservices account deployment create --subscription $subscription_id --deployment-name $deployment_name --model-name $model_name" >&2
    return 0
  fi

  az cognitiveservices account deployment create \
    --name "$account_name" \
    --resource-group "$resource_group" \
    --subscription "$subscription_id" \
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
  require_command flock

  local input_name="${INPUT_FILE##*/}"
  local batch_name="${input_name%.csv}"
  local output_csv
  if [[ "$input_name" == "subscriptions.csv" ]]; then
    output_csv="${OUT_DIR}/foundry-endpoints.csv"
  else
    batch_name="${batch_name#subscriptions-}"
    if [[ -z "$batch_name" ]]; then
      echo "ERROR: Cannot derive a batch name from input filename: $INPUT_FILE" >&2
      exit 1
    fi
    output_csv="${OUT_DIR}/foundry-endpoints-${batch_name}.csv"
  fi
  if [[ "$INPUT_FILE" -ef "$output_csv" ]]; then
    echo "ERROR: Input and output must be different files: $output_csv" >&2
    exit 1
  fi

  log "Validating Azure CLI login..."
  az account show --output none --only-show-errors

  log "=== Model Deployment ==="
  log "Input file:     $INPUT_FILE"
  log "TPM override:   ${TPM_OVERRIDE:-<default per model>}"
  log "Dry run:        $DRY_RUN"
  log "Output dir:     $OUT_DIR"
  log "Inventory file: $output_csv"
  log "========================"

  # Pre-read CSV to collect subscriptions for confirmation
  local -a sub_entries=()
  local line_num=0

  while IFS=',' read -r subscription_id subscription_name prefix model_type location anthropic_org anthropic_industry anthropic_country || [[ -n "$subscription_id" ]]; do
    line_num=$((line_num + 1))
    if [[ "$line_num" -eq 1 ]]; then continue; fi

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

    sub_entries+=("${subscription_id}|${subscription_name}|${prefix}|${model_type}|${location}|${anthropic_org}|${anthropic_industry}|${anthropic_country}")
  done < "$INPUT_FILE"

  if [[ ${#sub_entries[@]} -eq 0 ]]; then
    log "No valid subscriptions found in CSV."
    return 0
  fi

  # Display deployment plan and ask for confirmation
  log "Deployment plan: ${#sub_entries[@]} subscription(s) to process:"
  for entry in "${sub_entries[@]}"; do
    IFS='|' read -r _sub_id sub_name _prefix m_type _rest <<< "$entry"
    log "  - $sub_name (type=$m_type)"
  done

  if [[ "$FORCE" != "true" && "$DRY_RUN" != "true" ]]; then
    echo "" >&2
    echo "Press Enter to continue, or Ctrl+C to abort..." >&2
    read -r
  fi

  mkdir -p "$OUT_DIR"

  local output_lock_fd
  exec {output_lock_fd}>>"${output_csv}.lock"
  if ! flock -n "$output_lock_fd"; then
    echo "ERROR: Another process is writing $output_csv; use a different batch name or wait for it to finish." >&2
    exit 1
  fi
  printf "subscription_name,model_endpoint,model_name,model_type,access_key\n" > "$output_csv"

  local success_count=0
  local fail_count=0

  # Process each subscription — errors in one do not stop others
  for entry in "${sub_entries[@]}"; do
    IFS='|' read -r subscription_id subscription_name prefix model_type location anthropic_org anthropic_industry anthropic_country <<< "$entry"

    log "=== Processing: $subscription_name (sub=$subscription_id, type=$model_type) ==="

    # Wrap per-subscription work so failures don't kill the loop
    local subscription_status
    set +e
    (
      set -euo pipefail

      # Pass --subscription explicitly; the CLI default is shared across shells.
      # Auto-resolve Anthropic parameters from tenant if not specified in CSV
      if [[ "$model_type" == "claude" ]]; then
        resolve_anthropic_params "$subscription_id" anthropic_org anthropic_industry anthropic_country
      fi

      # Register providers
      register_providers "$subscription_id"

      # Create or reuse Foundry resource
      local account_name
      account_name="$(create_foundry_resource "$subscription_id" "$subscription_name" "$prefix" "$model_type" "$location")"
      log "  Foundry resource: $account_name"

      local resource_group="rg-foundry"
      create_foundry_project "$subscription_id" "$account_name" "$subscription_name" "$resource_group" "$location"

      local endpoint
      endpoint="$(get_endpoint "$subscription_id" "$account_name" "$resource_group" "$model_type")"

      # Deploy models based on model_type
      local models_list=""
      case "$model_type" in
        claude)   models_list="$CLAUDE_MODELS" ;;
        gpt)      models_list="$GPT_MODELS" ;;
        gpt-luna) models_list="$GPT_LUNA_MODELS" ;;
        deepseek) models_list="$DEEPSEEK_MODELS" ;;
        *)
          log "WARNING: Unknown model_type '$model_type', skipping"
          exit 0
          ;;
      esac

      # Get access key once per account (shared across all deployments)
      local access_key
      access_key="$(get_access_key "$subscription_id" "$account_name" "$resource_group")"

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
          gpt|gpt-luna)
            deploy_openai_model "$subscription_id" "$resource_group" "$account_name" "$m_name" "$m_version" "$tpm"
            ;;
          deepseek)
            deploy_deepseek_model "$subscription_id" "$resource_group" "$account_name" "$m_name" "$m_version" "$tpm"
            ;;
        esac

        # Write endpoint entry with model-type-appropriate path
        local model_endpoint
        case "$model_type" in
          claude)   model_endpoint="${endpoint%/}/anthropic/v1/messages" ;;
          gpt|gpt-luna)      model_endpoint="${endpoint%/}/openai/deployments/${m_name}" ;;
          deepseek) model_endpoint="${endpoint%/}/v1/chat/completions" ;;
          *)        model_endpoint="${endpoint%/}/openai/deployments/${m_name}" ;;
        esac
        printf "%s,%s,%s,%s,%s\n" \
          "$subscription_name" "$model_endpoint" "$m_name" "$model_type" "$access_key" \
          >> "$output_csv"
      done
    )
    subscription_status=$?
    set -e

    if [[ "$subscription_status" -ne 0 ]]; then
      log "  ERROR: Subscription $subscription_name had failures, continuing with next..."
      fail_count=$((fail_count + 1))
      continue
    fi

    success_count=$((success_count + 1))
  done

  log "=== Deployment complete ==="
  log "Endpoint inventory: $output_csv"
  if [[ -f "$output_csv" ]]; then
    local count
    count="$(tail -n +2 "$output_csv" | wc -l)"
    log "  $count model endpoints recorded"
  fi
  log "  Subscriptions: $success_count succeeded, $fail_count failed (of ${#sub_entries[@]} total)"
  log "Next step: scripts/test-endpoints.sh $output_csv"
}

main "$@"
