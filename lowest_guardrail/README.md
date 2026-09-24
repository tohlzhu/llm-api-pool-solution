# Lowest-block Foundry guardrail

`apply_lowest_guardrail.py` creates one reusable RAI policy and assigns it to
every model deployment in selected Microsoft Foundry/Azure OpenAI accounts.

## Behavior

- Defaults to a read-only dry run.
- Discovers account kinds `AIServices` and `OpenAI`.
- Can scope discovery to enabled subscriptions in a management group and all
  descendant management groups.
- Uses `LowestBlock` as the policy name by default.
- In `auto` mode, first requests annotate-only behavior for Hate, Sexual,
  Violence, and Selfharm. If Azure rejects that because Modified Content
  Filters approval is absent, it falls back to blocking `High` severity only.
- Keeps Jailbreak, Indirect Attack, Protected Material Text, and Protected
  Material Code enabled for annotations with `blocking=false`.
- Preserves each deployment's model, model version, SKU/capacity, upgrade
  option, scale settings, spillover deployment, parent deployment, and tags.
- Uses an ETag when Azure supplies one, so a concurrent deployment change
  causes a failure instead of being overwritten.
- Restores the Azure CLI's original default subscription before exit.

Azure can add platform-managed controls to the resulting policy. For example,
`DefenderForAI` is currently forced to `blocking=true` even when a policy PUT
requests `blocking=false`. The script reports such inherited blockers after
verification.

## Prerequisites

- Python 3.9 or later
- Azure CLI (`az`) signed in to every target tenant/subscription
- Permission to read the selected management-group hierarchy when using
  `--management-group` (`Microsoft.Management/managementGroups/read`)
- Permission to read and write these child resources:
  - `Microsoft.CognitiveServices/accounts/raiPolicies`
  - `Microsoft.CognitiveServices/accounts/deployments`

The Azure CLI login is separate from the VS Code Azure extension login. Check
the active CLI context with `az account show` before applying changes.

## One resource

Dry run:

```bash
python3 apply_lowest_guardrail.py \
  --resource-id /subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.CognitiveServices/accounts/<account-name>
```

Apply and verify:

```bash
python3 apply_lowest_guardrail.py \
  --resource-id /subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.CognitiveServices/accounts/<account-name> \
  --apply
```

## Multiple subscriptions

Repeat `--subscription` to discover every Foundry/OpenAI account in the named
subscriptions. Omit `--apply` for the initial inventory pass.

```bash
python3 apply_lowest_guardrail.py \
  --subscription <subscription-id-1> \
  --subscription <subscription-id-2> \
  --apply
```

To target every enabled subscription visible to the current Azure CLI login:

```bash
python3 apply_lowest_guardrail.py --all-subscriptions
python3 apply_lowest_guardrail.py --all-subscriptions --apply --yes
```

To target enabled subscriptions in a management group and all descendant
management groups, pass its name (not display name) or full resource ID.
Applying this bulk target requires `--yes`.

```bash
python3 apply_lowest_guardrail.py \
  --management-group <management-group-name>

python3 apply_lowest_guardrail.py \
  --management-group <management-group-name> \
  --apply \
  --yes
```

`--management-group`, `--subscription`, and `--resource-id` can be repeated or
combined. Results are deduplicated. Subscriptions that are disabled or not
visible to the current Azure CLI login are excluded.

## Policy options

```text
--core-mode auto           Try annotate-only, then fall back to high-only.
--core-mode annotate-only  Require no core-category blocking; fail if denied.
--core-mode high-only      Block only High severity for core categories.
--policy-name NAME         Override LowestBlock.
--base-policy NAME         Override automatic DefaultV2/Default detection.
--api-version VERSION      Override the ARM API version (2025-06-01).
```

The command exits nonzero if any account, policy, deployment update, or final
verification fails.