#!/usr/bin/env python3
"""Create and assign a least-blocking Foundry content filter policy."""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from typing import Any, Iterable, Sequence


MANAGEMENT_ENDPOINT = "https://management.azure.com"
DEFAULT_API_VERSION = "2025-06-01"
DEFAULT_POLICY_NAME = "LowestBlock"
SUPPORTED_ACCOUNT_KINDS = {"aiservices", "openai"}
CORE_CATEGORIES = ("Hate", "Sexual", "Violence", "Selfharm")
OPTIONAL_FILTERS = (
    ("Jailbreak", "Prompt"),
    ("Indirect Attack", "Prompt"),
    ("Indirect Attack", "PostToolCall"),
    ("Protected Material Text", "Completion"),
    ("Protected Material Code", "Completion"),
)
RESOURCE_ID_PATTERN = re.compile(
    r"^/subscriptions/(?P<subscription>[^/]+)/resourceGroups/(?P<resource_group>[^/]+)"
    r"/providers/Microsoft\.CognitiveServices/accounts/(?P<account>[^/]+)$",
    re.IGNORECASE,
)
SUBSCRIPTION_RESOURCE_ID_PATTERN = re.compile(
    r"^/subscriptions/(?P<subscription>[^/]+)$",
    re.IGNORECASE,
)


class AzureCliError(RuntimeError):
    def __init__(self, command: Sequence[str], return_code: int, message: str) -> None:
        self.command = command
        self.return_code = return_code
        self.message = message.strip()
        super().__init__(self.message or f"Azure CLI exited with code {return_code}")


@dataclass(frozen=True)
class Account:
    resource_id: str
    subscription_id: str
    resource_group: str
    name: str

    @classmethod
    def from_resource_id(cls, resource_id: str) -> "Account":
        normalized = resource_id.rstrip("/")
        match = RESOURCE_ID_PATTERN.match(normalized)
        if not match:
            raise ValueError(
                "Expected a Microsoft.CognitiveServices account resource ID, got: "
                f"{resource_id}"
            )
        return cls(
            resource_id=normalized,
            subscription_id=match.group("subscription"),
            resource_group=match.group("resource_group"),
            name=match.group("account"),
        )


def log(message: str) -> None:
    print(message, flush=True)


def warn(message: str) -> None:
    print(f"WARNING: {message}", file=sys.stderr, flush=True)


def run_az(
    arguments: Sequence[str],
    *,
    expect_json: bool = True,
) -> Any:
    command = ["az", *arguments, "--only-show-errors"]
    completed = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise AzureCliError(command, completed.returncode, completed.stderr or completed.stdout)

    output = completed.stdout.strip()
    if not expect_json:
        return output
    if not output:
        return None
    try:
        return json.loads(output)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"Azure CLI returned invalid JSON: {output}") from error


def arm_request(
    method: str,
    resource_id: str,
    api_version: str,
    body: dict[str, Any] | None = None,
    headers: dict[str, str] | None = None,
) -> Any:
    url = f"{MANAGEMENT_ENDPOINT}/{resource_id.lstrip('/')}?api-version={api_version}"
    arguments = ["rest", "--method", method, "--url", url, "--output", "json"]
    if body is not None:
        arguments.extend(("--body", json.dumps(body, separators=(",", ":"))))
    if headers:
        arguments.append("--headers")
        arguments.extend(f"{name}={value}" for name, value in headers.items())
    return run_az(arguments)


def unique(items: Iterable[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for item in items:
        key = item.casefold()
        if key not in seen:
            seen.add(key)
            result.append(item)
    return result


def enabled_subscriptions() -> list[str]:
    accounts = run_az(("account", "list", "--all", "--output", "json")) or []
    return [account["id"] for account in accounts if account.get("state") == "Enabled"]


def subscription_ids_from_management_group(
    management_group: dict[str, Any],
) -> list[str]:
    subscription_ids: list[str] = []

    def visit(node: dict[str, Any]) -> None:
        resource_id = str(node.get("id", "")).rstrip("/")
        match = SUBSCRIPTION_RESOURCE_ID_PATTERN.match(resource_id)
        if match:
            subscription_ids.append(match.group("subscription"))

        children = node.get("children")
        if isinstance(children, list):
            for child in children:
                if isinstance(child, dict):
                    visit(child)

    visit(management_group)
    return unique(subscription_ids)


def management_group_subscriptions(management_group: str) -> list[str]:
    management_group_name = management_group.rstrip("/").rsplit("/", 1)[-1]
    hierarchy = run_az(
        (
            "account",
            "management-group",
            "show",
            "--name",
            management_group_name,
            "--expand",
            "--recurse",
            "--output",
            "json",
        )
    )
    if not isinstance(hierarchy, dict):
        raise RuntimeError(
            f"Unexpected response while reading management group {management_group}"
        )

    enabled = {subscription_id.casefold() for subscription_id in enabled_subscriptions()}
    return [
        subscription_id
        for subscription_id in subscription_ids_from_management_group(hierarchy)
        if subscription_id.casefold() in enabled
    ]


def discover_accounts(subscription_ids: Iterable[str]) -> list[str]:
    resource_ids: list[str] = []
    for subscription_id in subscription_ids:
        log(f"Discovering Foundry accounts in subscription {subscription_id}...")
        resources = run_az(
            (
                "resource",
                "list",
                "--subscription",
                subscription_id,
                "--resource-type",
                "Microsoft.CognitiveServices/accounts",
                "--output",
                "json",
            )
        ) or []
        resource_ids.extend(
            resource["id"]
            for resource in resources
            if str(resource.get("kind", "")).casefold() in SUPPORTED_ACCOUNT_KINDS
        )
    return resource_ids


def build_policy(base_policy_name: str, core_mode: str) -> dict[str, Any]:
    core_blocking = core_mode == "high-only"
    content_filters: list[dict[str, Any]] = []
    for category in CORE_CATEGORIES:
        for source in ("Prompt", "Completion"):
            content_filters.append(
                {
                    "name": category,
                    "source": source,
                    "enabled": True,
                    "blocking": core_blocking,
                    "severityThreshold": "High",
                }
            )

    content_filters.extend(
        {
            "name": name,
            "source": source,
            "enabled": True,
            "blocking": False,
        }
        for name, source in OPTIONAL_FILTERS
    )
    return {
        "properties": {
            "basePolicyName": base_policy_name,
            "mode": "Blocking",
            "contentFilters": content_filters,
            "customBlocklists": [],
        }
    }


def choose_base_policy(policies: list[dict[str, Any]], requested: str | None) -> str:
    if requested:
        return requested
    names = {str(policy.get("name", "")) for policy in policies}
    if "Microsoft.DefaultV2" in names:
        return "Microsoft.DefaultV2"
    if "Microsoft.Default" in names:
        return "Microsoft.Default"
    raise RuntimeError("Neither Microsoft.DefaultV2 nor Microsoft.Default is available")


def put_policy(
    account: Account,
    policy_name: str,
    base_policy_name: str,
    core_mode: str,
    api_version: str,
) -> dict[str, Any]:
    policy_id = f"{account.resource_id}/raiPolicies/{policy_name}"
    response = arm_request(
        "put",
        policy_id,
        api_version,
        build_policy(base_policy_name, core_mode),
    )
    if not isinstance(response, dict):
        raise RuntimeError(f"Unexpected response while updating policy {policy_name}")
    return response


def deployment_update_body(
    deployment: dict[str, Any], policy_name: str
) -> dict[str, Any]:
    source_properties = deployment.get("properties", {})
    properties = {
        name: source_properties[name]
        for name in (
            "model",
            "parentDeploymentName",
            "scaleSettings",
            "spilloverDeploymentName",
            "versionUpgradeOption",
        )
        if source_properties.get(name) is not None
    }
    properties["raiPolicyName"] = policy_name

    body: dict[str, Any] = {"properties": properties}
    if deployment.get("sku") is not None:
        body["sku"] = deployment["sku"]
    if deployment.get("tags") is not None:
        body["tags"] = deployment["tags"]
    return body


def assign_policy(
    account: Account,
    deployment_name: str,
    policy_name: str,
    api_version: str,
) -> None:
    deployment_id = f"{account.resource_id}/deployments/{deployment_name}"
    deployment = arm_request("get", deployment_id, api_version)
    headers = {"If-Match": deployment["etag"]} if deployment.get("etag") else None
    arm_request(
        "put",
        deployment_id,
        api_version,
        deployment_update_body(deployment, policy_name),
        headers,
    )


def get_deployments(account: Account, api_version: str) -> list[dict[str, Any]]:
    response = arm_request("get", f"{account.resource_id}/deployments", api_version)
    return list(response.get("value", [])) if isinstance(response, dict) else []


def get_policies(account: Account, api_version: str) -> list[dict[str, Any]]:
    response = arm_request("get", f"{account.resource_id}/raiPolicies", api_version)
    return list(response.get("value", [])) if isinstance(response, dict) else []


def verify_account(
    account: Account,
    policy_name: str,
    api_version: str,
) -> tuple[list[str], str, list[str]]:
    deployments = get_deployments(account, api_version)
    mismatches = [
        deployment.get("name", "<unknown>")
        for deployment in deployments
        if deployment.get("properties", {}).get("raiPolicyName") != policy_name
    ]
    policy = arm_request(
        "get",
        f"{account.resource_id}/raiPolicies/{policy_name}",
        api_version,
    )
    core_filters = [
        item
        for item in policy.get("properties", {}).get("contentFilters", [])
        if item.get("name") in CORE_CATEGORIES
    ]
    effective_mode = (
        "annotate-only"
        if core_filters and all(item.get("blocking") is False for item in core_filters)
        else "high-only"
    )
    platform_blockers = sorted(
        {
            str(item.get("name"))
            for item in policy.get("properties", {}).get("contentFilters", [])
            if item.get("blocking") is True and item.get("name") not in CORE_CATEGORIES
        }
    )
    return mismatches, effective_mode, platform_blockers


def process_account(account: Account, args: argparse.Namespace) -> tuple[int, int, str]:
    run_az(
        ("account", "set", "--subscription", account.subscription_id),
        expect_json=False,
    )
    account_data = arm_request("get", account.resource_id, args.api_version)
    account_kind = str(account_data.get("kind", ""))
    if account_kind.casefold() not in SUPPORTED_ACCOUNT_KINDS:
        warn(f"Skipping {account.resource_id}: unsupported kind {account_kind!r}")
        return 0, 0, "skipped"

    deployments = get_deployments(account, args.api_version)
    policies = get_policies(account, args.api_version)
    base_policy_name = choose_base_policy(policies, args.base_policy)
    existing_policy_names = {policy.get("name") for policy in policies}
    operation = "update" if args.policy_name in existing_policy_names else "create"
    operation_prefix = "will" if args.apply else "would"
    log(
        f"[{account.name}] {len(deployments)} deployment(s); {operation_prefix} {operation} "
        f"policy {args.policy_name} from {base_policy_name}."
    )

    if not args.apply:
        pending = sum(
            deployment.get("properties", {}).get("raiPolicyName") != args.policy_name
            for deployment in deployments
        )
        log(
            f"[{account.name}] DRY RUN: {pending} deployment(s) would be updated; "
            f"core mode={args.core_mode}."
        )
        return pending, 0, "dry-run"

    requested_mode = args.core_mode
    active_mode = "annotate-only" if requested_mode in {"auto", "annotate-only"} else "high-only"
    try:
        put_policy(
            account,
            args.policy_name,
            base_policy_name,
            active_mode,
            args.api_version,
        )
    except AzureCliError as error:
        if requested_mode != "auto":
            raise
        warn(
            f"[{account.name}] annotate-only policy was rejected; falling back to "
            f"high-only. Azure response: {error.message}"
        )
        active_mode = "high-only"
        put_policy(
            account,
            args.policy_name,
            base_policy_name,
            active_mode,
            args.api_version,
        )

    changed = 0
    failed = 0
    fallback_used = active_mode == "high-only"
    for deployment in deployments:
        deployment_name = str(deployment.get("name", ""))
        current_policy = deployment.get("properties", {}).get("raiPolicyName")
        if current_policy == args.policy_name:
            log(f"[{account.name}/{deployment_name}] already assigned; skipping.")
            continue
        try:
            assign_policy(
                account,
                deployment_name,
                args.policy_name,
                args.api_version,
            )
        except AzureCliError as error:
            if requested_mode == "auto" and not fallback_used:
                warn(
                    f"[{account.name}/{deployment_name}] annotate-only assignment was "
                    f"rejected; replacing the policy with high-only. Azure response: "
                    f"{error.message}"
                )
                put_policy(
                    account,
                    args.policy_name,
                    base_policy_name,
                    "high-only",
                    args.api_version,
                )
                active_mode = "high-only"
                fallback_used = True
                try:
                    assign_policy(
                        account,
                        deployment_name,
                        args.policy_name,
                        args.api_version,
                    )
                except AzureCliError as retry_error:
                    failed += 1
                    warn(f"[{account.name}/{deployment_name}] failed: {retry_error.message}")
                    continue
            else:
                failed += 1
                warn(f"[{account.name}/{deployment_name}] failed: {error.message}")
                continue
        changed += 1
        log(f"[{account.name}/{deployment_name}] assigned {args.policy_name}.")

    mismatches, effective_mode, platform_blockers = verify_account(
        account,
        args.policy_name,
        args.api_version,
    )
    if mismatches:
        failed += len(mismatches)
        warn(f"[{account.name}] verification mismatches: {', '.join(mismatches)}")
    else:
        log(
            f"[{account.name}] verified all {len(deployments)} deployment(s); "
            f"effective core mode={effective_mode}."
        )
        if platform_blockers:
            log(
                f"[{account.name}] platform-enforced blocking remains active for: "
                f"{', '.join(platform_blockers)}."
            )
    return changed, failed, effective_mode


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Create the least-blocking supported Foundry RAI policy and assign it "
            "to every deployment. The default is a read-only dry run."
        )
    )
    target = parser.add_argument_group("targets")
    target.add_argument(
        "--resource-id",
        action="append",
        default=[],
        help="Exact Microsoft.CognitiveServices account resource ID; repeatable.",
    )
    target.add_argument(
        "--subscription",
        action="append",
        default=[],
        help="Discover AIServices/OpenAI accounts in this subscription; repeatable.",
    )
    target.add_argument(
        "--management-group",
        action="append",
        default=[],
        help=(
            "Discover accounts in enabled subscriptions under this management group "
            "and its descendants; name or resource ID; repeatable."
        ),
    )
    target.add_argument(
        "--all-subscriptions",
        action="store_true",
        help="Discover accounts in every enabled subscription visible to Azure CLI.",
    )
    parser.add_argument("--policy-name", default=DEFAULT_POLICY_NAME)
    parser.add_argument("--base-policy", help="Override Microsoft.DefaultV2 auto-detection.")
    parser.add_argument("--api-version", default=DEFAULT_API_VERSION)
    parser.add_argument(
        "--core-mode",
        choices=("auto", "annotate-only", "high-only"),
        default="auto",
        help=(
            "auto tries no blocking first and falls back to blocking High severity only; "
            "default: auto."
        ),
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Create/update the policy and deployment assignments.",
    )
    parser.add_argument(
        "--yes",
        action="store_true",
        help=(
            "Required with --apply when using --all-subscriptions or "
            "--management-group."
        ),
    )
    args = parser.parse_args()

    if not (
        args.resource_id
        or args.subscription
        or args.management_group
        or args.all_subscriptions
    ):
        parser.error(
            "Specify --resource-id, --subscription, --management-group, "
            "or --all-subscriptions"
        )
    if (args.all_subscriptions or args.management_group) and args.apply and not args.yes:
        parser.error(
            "--all-subscriptions/--management-group with --apply also requires --yes"
        )
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", args.policy_name):
        parser.error("--policy-name contains unsupported characters")
    return args


def main() -> int:
    args = parse_args()
    if shutil.which("az") is None:
        raise RuntimeError("Azure CLI (az) is required")

    original_account = run_az(("account", "show", "--output", "json"))
    original_subscription = original_account.get("id") if original_account else None
    failures = 0
    changed = 0
    try:
        subscription_ids = list(args.subscription)
        for management_group in args.management_group:
            subscription_ids.extend(management_group_subscriptions(management_group))
        if args.all_subscriptions:
            subscription_ids.extend(enabled_subscriptions())

        resource_ids = list(args.resource_id)
        resource_ids.extend(discover_accounts(unique(subscription_ids)))
        accounts = [Account.from_resource_id(item) for item in unique(resource_ids)]
        log(f"Selected {len(accounts)} Foundry account(s).")

        for account in accounts:
            try:
                account_changed, account_failures, _ = process_account(account, args)
                changed += account_changed
                failures += account_failures
            except (AzureCliError, RuntimeError, ValueError) as error:
                failures += 1
                warn(f"[{account.name}] account processing failed: {error}")
    finally:
        if original_subscription:
            try:
                run_az(
                    ("account", "set", "--subscription", original_subscription),
                    expect_json=False,
                )
            except AzureCliError as error:
                warn(f"Could not restore the original subscription: {error.message}")

    log(f"Summary: changed/planned={changed}, failures={failures}.")
    return 1 if failures else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130) from None
    except (AzureCliError, RuntimeError, ValueError) as error:
        warn(str(error))
        raise SystemExit(1) from None