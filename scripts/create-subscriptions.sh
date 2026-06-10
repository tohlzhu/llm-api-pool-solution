#!/usr/bin/env bash
set -euo pipefail

# create-subscriptions.sh — Phase 1: Create Azure subscriptions for the LLM API pool.
# Outputs a parameter CSV consumed by deploy-models.sh.
# Requires EA/MCA billing scope with subscription creation permissions.

# ---------- Defaults ----------

PREFIX="${PREFIX:-llmpool}"
LOCATION="${LOCATION:-eastus2}"
COUNT="${COUNT:-10}"
BILLING_SCOPE="${BILLING_SCOPE:-}"
MANAGEMENT_GROUP_ID="${MANAGEMENT_GROUP_ID:-}"
OUT_DIR="${OUT_DIR:-./generated}"
DRY_RUN="${DRY_RUN:-false}"

MODEL_TYPE=""
ANTHROPIC_ORG="${ANTHROPIC_ORG:-Contoso Pte.Ltd}"
ANTHROPIC_INDUSTRY="${ANTHROPIC_INDUSTRY:-Manufacturing}"
ANTHROPIC_COUNTRY="${ANTHROPIC_COUNTRY:-SG}"

# ---------- CLI argument parsing ----------

usage() {
  cat <<EOF >&2
Usage: $(basename "$0") [OPTIONS]

Create Azure subscriptions for a multi-subscription Foundry pool.
Outputs a CSV parameter file for use with deploy-models.sh.

Options:
  -p, --prefix PREFIX           Naming prefix (default: llmpool)
      --claude                  Model type: Claude (last specified wins)
      --gpt                     Model type: GPT (last specified wins)
      --deepseek                Model type: DeepSeek (last specified wins)
      --anthropic-org NAME      Claude organizationName (default: Contoso Pte.Ltd)
      --anthropic-industry V    Claude industry (default: Manufacturing)
      --anthropic-country CC    Claude countryCode (default: SG)
  -n, --count N                 Number of subscriptions to create (default: 10)
  -l, --location LOCATION       Azure region (default: eastus2)
  -s, --billing-scope SCOPE     EA/MCA billing scope (required, see below)
  -m, --mgmt-group ID           Management group ID (optional)
      --dry-run                 Print actions without executing
  -h, --help                    Show this help

At least one model type must be specified: --claude, --gpt, or --deepseek.
If multiple are specified, the last one wins (one subscription batch = one model type).

Billing scope format (full ARM resource ID):
  EA:  /providers/Microsoft.Billing/billingAccounts/{billingAccountId}/enrollmentAccounts/{enrollmentAccountId}
       Find via: az billing enrollment-account list --query "[].id" -o tsv
  MCA: /providers/Microsoft.Billing/billingAccounts/{billingAccountId}/billingProfiles/{billingProfileId}/invoiceSections/{invoiceSectionId}
       Find via: az billing invoice section list --billing-account-name <ID> --billing-profile-name <ID> --query "[].id" -o tsv
  MPA: /providers/Microsoft.Billing/billingAccounts/{billingAccountId}/customers/{customerId}
  Portal: Cost Management + Billing -> Billing scopes / Invoice sections -> Properties -> ID

Output:
  \$OUT_DIR/subscriptions.csv — columns:
    subscription_id, subscription_name, prefix, model_type, location,
    anthropic-org, anthropic-industry, anthropic-country
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--prefix)             PREFIX="$2"; shift 2 ;;
    --claude)                MODEL_TYPE="claude"; shift ;;
    --gpt)                   MODEL_TYPE="gpt"; shift ;;
    --deepseek)              MODEL_TYPE="deepseek"; shift ;;
    --anthropic-org)         ANTHROPIC_ORG="$2"; shift 2 ;;
    --anthropic-industry)    ANTHROPIC_INDUSTRY="$2"; shift 2 ;;
    --anthropic-country)     ANTHROPIC_COUNTRY="$2"; shift 2 ;;
    -n|--count)              COUNT="$2"; shift 2 ;;
    -l|--location)           LOCATION="$2"; shift 2 ;;
    -s|--billing-scope)      BILLING_SCOPE="$2"; shift 2 ;;
    -m|--mgmt-group)         MANAGEMENT_GROUP_ID="$2"; shift 2 ;;
    --dry-run)               DRY_RUN="true"; shift ;;
    -h|--help)               usage ;;
    *)                       echo "Unknown option: $1" >&2; usage ;;
  esac
done

# ---------- Validation ----------

if [[ -z "$MODEL_TYPE" ]]; then
  echo "ERROR: Model type is required (--claude, --gpt, or --deepseek)" >&2
  exit 1
fi

if [[ -z "$BILLING_SCOPE" ]]; then
  echo "ERROR: --billing-scope is required" >&2
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

# ---------- Subscription management ----------

create_subscription_alias() {
  local index="$1"
  local sub_name="${PREFIX}-${MODEL_TYPE}-sub${index}"
  local alias_name="${sub_name}"

  local body
  body=$(cat <<JSON
{
  "properties": {
    "billingScope": "${BILLING_SCOPE}",
    "displayName": "${sub_name}",
    "workLoad": "Production"
  }
}
JSON
)

  log "Creating subscription alias: $alias_name (display: $sub_name)"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] az rest --method put --url https://management.azure.com/providers/Microsoft.Subscription/aliases/${alias_name}?api-version=2021-10-01" >&2
    echo "dry-run-sub-id-${index}"
    return 0
  fi

  az rest --only-show-errors --method put \
    --url "https://management.azure.com/providers/Microsoft.Subscription/aliases/${alias_name}?api-version=2021-10-01" \
    --body "$body" --output none

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
      az account list --refresh --only-show-errors >/dev/null 2>&1 || true
      az rest --only-show-errors --method get \
        --url "https://management.azure.com/providers/Microsoft.Subscription/aliases/${alias_name}?api-version=2021-10-01" \
        --query "properties.subscriptionId" -o tsv
      return 0
    fi

    if [[ "$state" == "Failed" || "$state" == "Canceled" ]]; then
      echo "ERROR: Subscription alias $alias_name reached state: $state" >&2
      return 1
    fi

    log "  Waiting for $alias_name (state: ${state:-unknown})..."
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
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] az account management-group subscription add --name $MANAGEMENT_GROUP_ID --subscription $subscription_id" >&2
    return 0
  fi
  log "  Moving $subscription_id to management group $MANAGEMENT_GROUP_ID"
  az account management-group subscription add \
    --name "$MANAGEMENT_GROUP_ID" \
    --subscription "$subscription_id" --only-show-errors
}

# ---------- Main ----------

main() {
  require_command az

  log "Validating Azure CLI login..."
  az account show --output none --only-show-errors

  log "=== Subscription Creation ==="
  log "Prefix:           $PREFIX"
  log "Model type:       $MODEL_TYPE"
  log "Count:            $COUNT"
  log "Location:         $LOCATION"
  log "Management group: ${MANAGEMENT_GROUP_ID:-<none>}"
  log "Anthropic org:    $ANTHROPIC_ORG"
  log "Anthropic ind:    $ANTHROPIC_INDUSTRY"
  log "Anthropic ctry:   $ANTHROPIC_COUNTRY"
  log "Dry run:          $DRY_RUN"
  log "Output dir:       $OUT_DIR"
  log "============================="

  mkdir -p "$OUT_DIR"

  local csv_file="${OUT_DIR}/subscriptions.csv"

  # Append mode: create header only if file doesn't exist or is empty
  if [[ ! -s "$csv_file" ]]; then
    printf "subscription_id,subscription_name,prefix,model_type,location,anthropic-org,anthropic-industry,anthropic-country\n" > "$csv_file"
  fi

  local created=0
  local skipped=0

  for index in $(seq 1 "$COUNT"); do
    local sub_name="${PREFIX}-${MODEL_TYPE}-sub${index}"
    log "--- Subscription $index/$COUNT: $sub_name ---"

    # Check if subscription already exists (match by display name pattern)
    if [[ "$DRY_RUN" != "true" ]]; then
      local existing_sub_id
      existing_sub_id="$(az account list --query "[?name=='${sub_name}'].id" -o tsv --only-show-errors 2>/dev/null || true)"
      if [[ -n "$existing_sub_id" ]]; then
        log "  Subscription already exists: $sub_name ($existing_sub_id), skipping creation"
        # Still append to CSV if not already there
        if ! grep -q "$existing_sub_id" "$csv_file" 2>/dev/null; then
          printf "%s,%s,%s,%s,%s,%s,%s,%s\n" \
            "$existing_sub_id" "$sub_name" "$PREFIX" "$MODEL_TYPE" "$LOCATION" \
            "$ANTHROPIC_ORG" "$ANTHROPIC_INDUSTRY" "$ANTHROPIC_COUNTRY" \
            >> "$csv_file"
        fi
        skipped=$((skipped + 1))
        continue
      fi
    fi

    local sub_id
    sub_id="$(create_subscription_alias "$index")"
    log "  Subscription ready: $sub_id"

    move_to_management_group "$sub_id"

    printf "%s,%s,%s,%s,%s,%s,%s,%s\n" \
      "$sub_id" "$sub_name" "$PREFIX" "$MODEL_TYPE" "$LOCATION" \
      "$ANTHROPIC_ORG" "$ANTHROPIC_INDUSTRY" "$ANTHROPIC_COUNTRY" \
      >> "$csv_file"
    created=$((created + 1))
  done

  log "=== Subscription creation complete ==="
  log "Parameter file: $csv_file"
  log "  Created: $created, Skipped (existing): $skipped, Total planned: $COUNT"
  log ""
  log "Next step: deploy models"
  log "  scripts/deploy-models.sh --input $csv_file"
}

main "$@"
