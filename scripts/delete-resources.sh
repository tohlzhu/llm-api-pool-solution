#!/usr/bin/env bash
set -euo pipefail

# delete-resources.sh — Delete Foundry resources created by deploy-models.sh.
# Deletes the resource group 'rg-foundry' in each subscription from the CSV,
# then purges soft-deleted Cognitive Services accounts to allow re-creation.

# ---------- Defaults ----------

INPUT_FILE="${INPUT_FILE:-./generated/subscriptions.csv}"
DRY_RUN="${DRY_RUN:-false}"
FORCE="${FORCE:-false}"
PURGE="${PURGE:-true}"

# ---------- CLI argument parsing ----------

usage() {
  cat <<EOF >&2
Usage: $(basename "$0") [OPTIONS]

Delete Foundry resources (rg-foundry) in subscriptions listed in the CSV.

Options:
  -i, --input FILE    Input CSV file (default: ./generated/subscriptions.csv)
      --force         Skip confirmation prompt
      --no-purge      Skip purging soft-deleted Cognitive Services accounts
      --dry-run       Print actions without executing
  -h, --help          Show this help

This script deletes the resource group 'rg-foundry' in each subscription,
which cascade-deletes all Foundry accounts and deployments.
By default, it also purges soft-deleted accounts to allow immediate re-creation.
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input)   INPUT_FILE="$2"; shift 2 ;;
    --force)      FORCE="true"; shift ;;
    --no-purge)   PURGE="false"; shift ;;
    --dry-run)    DRY_RUN="true"; shift ;;
    -h|--help)    usage ;;
    *)            echo "Unknown option: $1" >&2; usage ;;
  esac
done

# ---------- Helpers ----------

log() {
  echo "[$(date '+%H:%M:%S')] $*" >&2
}

# ---------- Main ----------

main() {
  if [[ ! -f "$INPUT_FILE" ]]; then
    echo "ERROR: Input file not found: $INPUT_FILE" >&2
    exit 1
  fi

  log "=== Resource Deletion ==="
  log "Input file: $INPUT_FILE"
  log "Dry run:    $DRY_RUN"
  log "Force:      $FORCE"
  log "Purge:      $PURGE"

  # Collect unique subscriptions (use fd 3 to avoid az consuming stdin)
  local -a sub_list=()
  local line_num=0

  while IFS=',' read -r subscription_id subscription_name prefix model_type location _rest <&3 || [[ -n "$subscription_id" ]]; do
    line_num=$((line_num + 1))
    if [[ "$line_num" -eq 1 ]]; then continue; fi

    subscription_id="$(echo "$subscription_id" | xargs)"
    subscription_name="$(echo "$subscription_name" | xargs)"

    if [[ -z "$subscription_id" ]]; then continue; fi

    sub_list+=("${subscription_id}|${subscription_name}")
  done 3< "$INPUT_FILE"

  if [[ ${#sub_list[@]} -eq 0 ]]; then
    log "No subscriptions found in CSV."
    return 0
  fi

  log "Deletion plan: ${#sub_list[@]} subscription(s) to process (rg-foundry):"
  for entry in "${sub_list[@]}"; do
    local sub_id="${entry%%|*}"
    local sub_name="${entry##*|}"
    log "  - $sub_name ($sub_id)"
  done

  if [[ "$FORCE" != "true" && "$DRY_RUN" != "true" ]]; then
    echo "" >&2
    echo "WARNING: This will delete resource group 'rg-foundry' in ${#sub_list[@]} subscription(s)." >&2
    echo "Press Enter to continue, or Ctrl+C to abort..." >&2
    read -r
  fi

  # Delete resource groups — errors in one subscription don't stop others
  local processed=0
  for entry in "${sub_list[@]}"; do
    local sub_id="${entry%%|*}"
    local sub_name="${entry##*|}"
    local resource_group="rg-foundry"

    log "--- Subscription: $sub_name ($sub_id) ---"

    if [[ "$DRY_RUN" == "true" ]]; then
      echo "[DRY-RUN] az account set --subscription $sub_id" >&2
      echo "[DRY-RUN] az group delete --name $resource_group --yes" >&2
      processed=$((processed + 1))
      continue
    fi

    if ! az account set --subscription "$sub_id" --only-show-errors 2>/dev/null; then
      log "  ERROR: Failed to set subscription, continuing with next..."
      continue
    fi

    # Check if resource group exists
    if ! az group show --name "$resource_group" --output none --only-show-errors 2>/dev/null; then
      log "  Resource group $resource_group does not exist, skipping"
      processed=$((processed + 1))
      continue
    fi

    log "  Deleting resource group: $resource_group"
    az group delete --name "$resource_group" --yes --no-wait --only-show-errors || {
      log "  ERROR: Failed to delete $resource_group in $sub_name, continuing..."
      continue
    }
    processed=$((processed + 1))
  done

  # Wait for deletions
  if [[ "$DRY_RUN" != "true" ]]; then
    log "Waiting for resource group deletions to complete..."
    for entry in "${sub_list[@]}"; do
      local sub_id="${entry%%|*}"
      local sub_name="${entry##*|}"
      local resource_group="rg-foundry"

      az account set --subscription "$sub_id" --only-show-errors

      for attempt in $(seq 1 60); do
        if ! az group show --name "$resource_group" --output none --only-show-errors 2>/dev/null; then
          log "  $sub_name: rg-foundry deleted"
          break
        fi
        if [[ "$attempt" -eq 60 ]]; then
          log "  WARNING: Timed out waiting for $resource_group deletion in $sub_name"
        fi
        sleep 10
      done
    done
  fi

  # Purge soft-deleted Cognitive Services accounts
  if [[ "$PURGE" == "true" && "$DRY_RUN" != "true" ]]; then
    log "Purging soft-deleted Cognitive Services accounts..."
    for entry in "${sub_list[@]}"; do
      local sub_id="${entry%%|*}"
      local sub_name="${entry##*|}"

      az account set --subscription "$sub_id" --only-show-errors

      local deleted_accounts
      deleted_accounts="$(az cognitiveservices account list-deleted --only-show-errors \
        --query "[].{name:name, rg:resourceGroup, location:location}" -o json 2>/dev/null || echo "[]")"

      local count
      count="$(echo "$deleted_accounts" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")"

      if [[ "$count" -gt 0 ]]; then
        log "  $sub_name: purging $count soft-deleted account(s)..."
        echo "$deleted_accounts" | python3 -c "
import sys, json
for acct in json.load(sys.stdin):
    print(f\"{acct['name']}|{acct['rg']}|{acct['location']}\")
" | while IFS='|' read -r acct_name acct_rg acct_location; do
          log "    Purging: $acct_name"
          az cognitiveservices account purge \
            --name "$acct_name" \
            --resource-group "$acct_rg" \
            --location "$acct_location" --only-show-errors 2>/dev/null || true
        done
      else
        log "  $sub_name: no soft-deleted accounts"
      fi
    done
  fi

  log "=== Deletion complete ==="
  log "  Processed: $processed of ${#sub_list[@]} subscription(s)"
}

main "$@"
