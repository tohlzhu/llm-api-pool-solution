#!/usr/bin/env python3
import argparse
import copy
import csv
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
from decimal import Decimal, InvalidOperation
from urllib.parse import quote


class DeploymentError(Exception):
    pass


def log(message):
    print(f"[{time.strftime('%H:%M:%S')}] {message}", file=sys.stderr, flush=True)


def json_object(value):
    try:
        result = json.loads(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"Invalid JSON: {error}") from error
    if not isinstance(result, dict):
        raise argparse.ArgumentTypeError("Expected a JSON object")
    return result


def positive_number(value):
    try:
        number = float(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("Expected a positive number") from error
    if not 0 < number < float('inf'):
        raise argparse.ArgumentTypeError("Expected a finite positive number")
    return number


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        prog='deploy-single-model.py',
        description="Reconcile or delete one model deployment per subscription, ignoring CSV model_type.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""Input CSV (compatible with create-subscriptions.sh):
  subscription_id,subscription_name,prefix,model_type,location,
  anthropic-org,anthropic-industry,anthropic-country
  model_type is optional and is only retained in resource tags.
  Optional resource_group,account_name,project_name columns override defaults;
  explicit command-line name overrides take precedence over CSV columns.

Default resources: rg-foundry / fdry-<subscription_name> / proj-<subscription_name>.
Deployments are account-scoped, as in deploy-models.sh; the project is ensured first
unless --direct skips all provider and intermediate resource checks/creation.
In direct mode CSV location must match the existing Foundry account's region.
sku_capacity is the exact Azure SKU capacity, NOT TPM; no division by 1000 occurs.
Omit sku_capacity (five fields, or an empty sixth field) to use available quota.
An explicit capacity is capped at quota availability and SKU capacity constraints.
Updates can reuse the existing deployment's capacity in the same quota pool.
Extra writable deployment properties (e.g. model.source, modelProviderData,
versionUpgradeOption, raiPolicyName) can be supplied with --deployment-properties.
Anthropic provider data otherwise comes from the CSV, with tenant lookup as needed.
Existing unspecified deployment settings are preserved in deploy mode.
--delete removes only the named deployment and always skips intermediate resources
and quota checks. --model-info may then contain just deployment_name; other model
fields are ignored. Missing deployments are skipped; deletion waits for absence.
Deletion also supports --dry-run and requires confirmation unless --force is used.
Only a deployment summary is emitted; existing endpoint CSVs are not overwritten.
Requires Python 3 (standard library only) and a logged-in Azure CLI.

Example targeting an existing Foundry account and project:
  python3 scripts/deploy-single-model.py --input ./generated/subscriptions-test1.csv \\
    --resource-group rg-admin-4378 --account-name fdry-admin-4379 \\
    --project-name proj-admin-4379 \\
    --direct --model-info 'gpt-6-luna|gpt-6-luna|2026-09-22|OpenAI|GlobalStandard'
""",
    )
    parser.add_argument('-i', '--input', default=os.environ.get('INPUT_FILE', './generated/subscriptions.csv'))
    parser.add_argument('--model-info', required=True,
                        metavar='deployment_name|model_name|model_version|model_format|sku_name[|sku_capacity]')
    parser.add_argument('--resource-group', help='Override the resource group for every subscription')
    parser.add_argument('--account-name', help='Override the Foundry account for every subscription')
    parser.add_argument('--project-name', help='Override the Foundry project for every subscription')
    parser.add_argument('--direct', action='store_true',
                        help='Skip providers and resource group/account/project checks; probe only the deployment')
    parser.add_argument('--delete', action='store_true',
                        help='Delete the named deployment if it exists; never create resources or query quota')
    parser.add_argument('--deployment-properties', type=json_object, default={}, metavar='JSON',
                        help='Additional writable deployment properties; explicit values are reconciled')
    parser.add_argument('--api-version', default=os.environ.get('DEPLOYMENT_API_VERSION', '2025-10-01-preview'))
    parser.add_argument('--wait-timeout', type=positive_number, default=600, metavar='SECONDS')
    parser.add_argument('--poll-interval', type=positive_number, default=5, metavar='SECONDS')
    parser.add_argument('--force', action='store_true', default=os.environ.get('FORCE') == 'true')
    parser.add_argument('--dry-run', action='store_true', default=os.environ.get('DRY_RUN') == 'true',
                        help='Read existing resources and print writes without executing them')
    args = parser.parse_args(argv)
    fields = [field.strip() for field in args.model_info.split('|')]
    if args.delete:
        if len(fields) not in (1, 5, 6) or not fields[0]:
            parser.error('--delete requires deployment_name or the usual five/six-field --model-info')
        args.deployment_name = fields[0]
    else:
        if len(fields) not in (5, 6) or not all(fields[:5]):
            parser.error('--model-info requires five non-empty pipe-separated fields and an optional capacity')
        if len(fields) == 5:
            fields.append('')
        if fields[5] and not re.fullmatch(r'[0-9]+', fields[5]):
            parser.error('sku_capacity must be a non-negative integer in Azure SKU units')
        args.deployment_name, name, version, model_format, sku_name, capacity = fields
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,63}', args.deployment_name):
        parser.error('deployment_name must be 1-64 letters, digits, underscores, dots or hyphens')
    if args.delete:
        return args
    args.model = {'name': name, 'version': version, 'format': model_format}
    args.sku = {'name': sku_name, 'capacity': int(capacity) if capacity else None}
    properties = args.deployment_properties
    if 'model' in properties and not isinstance(properties['model'], dict):
        parser.error('deployment-properties.model must be an object')
    for key, value in args.model.items():
        if key in properties.get('model', {}) and properties['model'][key] != value:
            parser.error(f'deployment-properties.model.{key} conflicts with --model-info')
    if 'modelProviderData' in properties and not isinstance(properties['modelProviderData'], dict):
        parser.error('deployment-properties.modelProviderData must be an object')
    return args


def read_subscriptions(path, direct=False, delete=False):
    with open(path, newline='', encoding='utf-8-sig') as source:
        reader = csv.DictReader(source, skipinitialspace=True)
        required = {'subscription_id', 'subscription_name'}
        if not delete:
            required.add('location')
        if not direct and not delete:
            required.add('prefix')
        if reader.fieldnames is None:
            raise DeploymentError('Input CSV is empty')
        reader.fieldnames = [name.strip() for name in reader.fieldnames]
        missing = required - set(reader.fieldnames)
        if missing:
            raise DeploymentError(f"Missing CSV columns: {', '.join(sorted(missing))}")
        rows = []
        for row in reader:
            if None in row:
                raise DeploymentError(f'CSV line {reader.line_num}: unexpected extra fields')
            row = {key: (value or '').strip() for key, value in row.items()}
            if not any(row.values()):
                continue
            if any(not row[key] for key in required):
                raise DeploymentError(f'CSV line {reader.line_num}: required field is empty')
            rows.append(row)
        return rows


class Azure:
    def __init__(self, subscription_id, dry_run):
        self.subscription_id = subscription_id
        self.dry_run = dry_run

    def run(self, *arguments, missing_ok=False, write=False):
        command = ['az', *arguments, '--subscription', self.subscription_id,
                   '--only-show-errors', '--output', 'json']
        if write and self.dry_run:
            log('[DRY-RUN] ' + shlex.join(command))
            return None
        result = subprocess.run(command, text=True, capture_output=True, check=False)
        if result.returncode:
            # Only a resource-not-found response means creation is safe to attempt.
            not_found = r'(?:ResourceNotFound|ResourceGroupNotFound|AccountNotFound|DeploymentNotFound|NotFound)'
            if missing_ok and (re.search(r'\(' + not_found + r'\)', result.stderr)
                               or re.search(r'"code"\s*:\s*"' + not_found + r'"', result.stderr)):
                return None
            raise DeploymentError(result.stderr.strip() or f'Azure CLI exited with {result.returncode}')
        if not result.stdout.strip():
            return None
        try:
            return json.loads(result.stdout)
        except ValueError as error:
            raise DeploymentError('Azure CLI returned invalid JSON') from error


def merge(base, overrides):
    result = copy.deepcopy(base)
    for key, value in overrides.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = merge(result[key], value)
        else:
            result[key] = copy.deepcopy(value)
    return result


def matches(actual, desired):
    if isinstance(desired, dict):
        return isinstance(actual, dict) and all(
            key in actual and matches(actual[key], value) for key, value in desired.items()
        )
    return actual == desired


def ensure_providers(azure):
    for provider in ('Microsoft.CognitiveServices', 'Microsoft.MachineLearningServices',
                     'Microsoft.SaaS', 'Microsoft.MarketplaceOrdering'):
        state = azure.run('provider', 'show', '--namespace', provider, '--query', 'registrationState')
        if state != 'Registered':
            log(f'  Registering {provider}')
            azure.run('provider', 'register', '--namespace', provider, '--wait', write=True)


def resource_names(row, args):
    group = args.resource_group or row.get('resource_group') or 'rg-foundry'
    account = args.account_name or row.get('account_name') or f"fdry-{row['subscription_name']}"
    project = args.project_name or row.get('project_name') or f"proj-{row['subscription_name']}"
    return group, account, project


def ensure_resources(azure, row, args):
    group, account, project = resource_names(row, args)
    tags = ['workload=llm-api-pool', f"prefix={row['prefix']}", f"model_type={row.get('model_type', '')}"]
    if azure.run('group', 'show', '--name', group, missing_ok=True) is None:
        log(f'  Creating resource group: {group}')
        azure.run('group', 'create', '--name', group, '--location', row['location'], '--tags', *tags, write=True)
    account_args = ['--name', account, '--resource-group', group]
    foundry = azure.run('cognitiveservices', 'account', 'show', *account_args, missing_ok=True)
    if foundry is None:
        deleted = azure.run('cognitiveservices', 'account', 'list-deleted') or []
        if any(item.get('name') == account for item in deleted):
            raise DeploymentError(f'Foundry account {account} is soft-deleted; recover or purge it explicitly first')
        log(f'  Creating Foundry resource: {account}')
        foundry = azure.run(
            'cognitiveservices', 'account', 'create', *account_args,
            '--location', row['location'], '--kind', 'AIServices', '--sku', 'S0',
            '--custom-domain', account, '--allow-project-management', 'true',
            '--assign-identity', '--tags', *tags, write=True,
        )
        if not azure.dry_run:
            try:
                user = azure.run('ad', 'signed-in-user', 'show', '--query', 'id')
                if user:
                    scope = (f'/subscriptions/{azure.subscription_id}/resourceGroups/{group}'
                             f'/providers/Microsoft.CognitiveServices/accounts/{account}')
                    azure.run('role', 'assignment', 'create', '--assignee', user,
                              '--role', 'Cognitive Services OpenAI User', '--scope', scope, write=True)
            except DeploymentError as error:
                log(f'  WARNING: Could not assign deploying-user role: {error}')
    elif foundry.get('properties', {}).get('allowProjectManagement') is not True:
        raise DeploymentError(f'Foundry account {account} does not have project management enabled')
    else:
        log(f'  Reusing Foundry resource: {account}')
    location = (foundry or {}).get('location', row['location'])
    project_args = [*account_args, '--project-name', project]
    if azure.run('cognitiveservices', 'account', 'project', 'show', *project_args, missing_ok=True) is None:
        log(f'  Creating Foundry project: {project}')
        azure.run('cognitiveservices', 'account', 'project', 'create', *project_args,
                  '--location', location, '--assign-identity', write=True)
    else:
        log(f'  Reusing Foundry project: {project}')
    return group, account, location


def jmes_literal(value):
    return '`' + json.dumps(value).replace('`', '\\`') + '`'


def quota_number(value):
    try:
        number = Decimal(str(value))
    except InvalidOperation as error:
        raise DeploymentError(f'Invalid quota/capacity value: {value!r}') from error
    if not number.is_finite() or number < 0:
        raise DeploymentError(f'Invalid quota/capacity value: {value!r}')
    return number


def find_model_sku(catalog, model, sku_name):
    candidates = []
    for item in catalog:
        if all(item.get(key) == model.get(key) for key in ('format', 'name', 'version')):
            candidates.extend(sku for sku in item.get('skus', []) if sku.get('name') == sku_name)
    unique = {json.dumps(item, sort_keys=True): item for item in candidates}
    if len(unique) != 1 or not next(iter(unique.values())).get('usageName'):
        raise DeploymentError(f'Cannot resolve an unambiguous quota metric for '
                              f'{model.get("format")}/{model.get("name")}/{model.get("version")} '
                              f'SKU {sku_name} in the target region')
    return next(iter(unique.values()))


def resolve_capacity(azure, location, args, existing):
    models = [args.model]
    old_model = (existing or {}).get('properties', {}).get('model', {})
    old_sku = (existing or {}).get('sku', {})
    old_capacity = (existing or {}).get('properties', {}).get('currentCapacity')
    if old_capacity is None:
        old_capacity = old_sku.get('capacity', 0)
    old_capacity = quota_number(old_capacity)
    if old_capacity and old_model not in models:
        models.append(old_model)
    conditions = ['(' + ' && '.join(f'model.{key}=={jmes_literal(model.get(key))}'
                                  for key in ('format', 'name', 'version')) + ')'
                  for model in models]
    sku_names = {args.sku['name']}
    if old_capacity:
        sku_names.add(old_sku.get('name'))
    sku_filter = ' || '.join(f'name=={jmes_literal(name)}' for name in sorted(sku_names))
    query = ("[?kind=='AIServices' && (" + ' || '.join(conditions) + ')].model.'
             '{name:name,version:version,format:format,skus:skus[?' + sku_filter + '].'
             '{name:name,usageName:usageName,capacity:capacity}}')
    catalog = azure.run('cognitiveservices', 'model', 'list', '--location', location,
                        '--query', query) or []
    sku = find_model_sku(catalog, args.model, args.sku['name'])
    usage_name = sku['usageName']
    metric_filter = "name.value eq '" + usage_name.replace("'", "''") + "'"
    usages = azure.run(
        'cognitiveservices', 'usage', 'list', '--location', location, '--filter', metric_filter,
        '--query', '[?name.value==' + jmes_literal(usage_name) + '].'
                   '{name:name.value,currentValue:currentValue,limit:limit}',
    ) or []
    if len(usages) != 1:
        raise DeploymentError(f'Cannot resolve quota usage for {usage_name} in {location}')
    limit = quota_number(usages[0].get('limit'))
    used = quota_number(usages[0].get('currentValue'))
    reusable = Decimal(0)
    if old_capacity:
        old_metric = find_model_sku(catalog, old_model, old_sku.get('name'))['usageName']
        if old_metric == usage_name:
            reusable = min(old_capacity, used)
    available = int(max(Decimal(0), limit - used + reusable))
    requested = args.sku['capacity']
    capacity = available if requested is None else min(requested, available)
    bounds = sku.get('capacity') or {}
    if bounds.get('maximum') is not None:
        capacity = min(capacity, int(quota_number(bounds['maximum'])))
    minimum = int(quota_number(bounds['minimum'])) if bounds.get('minimum') is not None else 1
    if bounds.get('allowedValues'):
        allowed = [int(quota_number(value)) for value in bounds['allowedValues']]
        capacity = max((value for value in allowed if minimum <= value <= capacity), default=-1)
    else:
        step = int(quota_number(bounds['step'])) if bounds.get('step') is not None else 1
        if step <= 0:
            raise DeploymentError(f'Invalid capacity step for {usage_name}: {step}')
        base = minimum if bounds.get('minimum') is not None else 0
        capacity -= (capacity - base) % step
    if capacity < minimum:
        raise DeploymentError(f'No deployable capacity for {usage_name}: available={available}, '
                              f'requested={requested}, minimum={minimum}; existing deployment is unchanged')
    log(f'  Quota {usage_name}: limit={limit}, used={used}, reusable={reusable}; '
        f'capacity {"auto" if requested is None else requested} -> {capacity}')
    return capacity


def desired_properties(azure, row, args):
    properties = merge(args.deployment_properties, {'model': args.model})
    if args.model['format'].lower() != 'anthropic':
        return properties
    provider = dict(properties.get('modelProviderData', {}))
    for key, column in (('organizationName', 'anthropic-org'), ('industry', 'anthropic-industry'),
                        ('countryCode', 'anthropic-country')):
        if not provider.get(key) and row.get(column):
            provider[key] = row[column]
    if not provider.get('organizationName') or not provider.get('countryCode'):
        tenant = azure.run('account', 'show', '--query', 'homeTenantId')
        if tenant:
            tenants = azure.run('rest', '--method', 'get', '--url',
                               'https://management.azure.com/tenants?api-version=2022-12-01',
                               '--query', f"value[?tenantId=='{tenant}']") or []
            if tenants:
                if not provider.get('organizationName'):
                    provider['organizationName'] = tenants[0].get('displayName')
                if not provider.get('countryCode'):
                    provider['countryCode'] = tenants[0].get('countryCode')
    if not provider.get('industry'):
        provider['industry'] = 'manufacturing'
    if not all(provider.get(key) for key in ('organizationName', 'industry', 'countryCode')):
        raise DeploymentError('Anthropic requires organizationName, industry and countryCode in '
                              '--deployment-properties modelProviderData or the anthropic-* CSV columns')
    properties['modelProviderData'] = provider
    return properties


def wait_for_deployment(azure, url, args, desired=None):
    deadline = time.monotonic() + args.wait_timeout
    while True:
        deployment = azure.run('rest', '--method', 'get', '--url', url)
        state = deployment.get('properties', {}).get('provisioningState')
        if state in ('Failed', 'Canceled', 'Cancelled'):
            raise DeploymentError(f'{args.deployment_name} reached provisioning state {state}')
        if state == 'Succeeded' and (desired is None or matches(deployment, desired)):
            return deployment
        if time.monotonic() >= deadline:
            raise DeploymentError(f'{args.deployment_name}: timed out waiting for requested settings '
                                  f'(provisioningState={state}); rerun to reconcile')
        time.sleep(args.poll_interval)


def delete_deployment(azure, url, args, existing):
    if existing is None:
        log(f'  {args.deployment_name}: does not exist; skipping deletion')
        return 'unchanged'
    if existing.get('properties', {}).get('provisioningState') != 'Deleting':
        log(f'  {args.deployment_name}: deleting')
        azure.run('rest', '--method', 'delete', '--url', url, missing_ok=True, write=True)
    else:
        log(f'  {args.deployment_name}: deletion already in progress')
    if azure.dry_run:
        return 'deleting'
    deadline = time.monotonic() + args.wait_timeout
    while True:
        remaining = azure.run('rest', '--method', 'get', '--url', url, missing_ok=True)
        if remaining is None:
            log(f'  {args.deployment_name}: deleted; absence verified')
            return 'deleted'
        if time.monotonic() >= deadline:
            raise DeploymentError(f'{args.deployment_name}: timed out waiting for deletion; '
                                  'rerun with --delete to check again')
        time.sleep(args.poll_interval)


def reconcile_deployment(azure, row, group, account, args, location=None):
    path = '/'.join(quote(part, safe='') for part in (
        'subscriptions', azure.subscription_id, 'resourceGroups', group, 'providers',
        'Microsoft.CognitiveServices', 'accounts', account, 'deployments', args.deployment_name,
    ))
    url = f'https://management.azure.com/{path}?api-version={quote(args.api_version, safe="")}'
    existing = azure.run('rest', '--method', 'get', '--url', url, missing_ok=True)
    if args.delete:
        return delete_deployment(azure, url, args, existing)
    properties = desired_properties(azure, row, args)
    desired = {'sku': args.sku, 'properties': properties}
    if existing is not None:
        state = existing.get('properties', {}).get('provisioningState')
        if state in ('Accepted', 'Creating', 'Updating', 'Scaling') and not azure.dry_run:
            existing = wait_for_deployment(azure, url, args)
        if (args.sku['capacity'] is not None
                and existing.get('properties', {}).get('provisioningState') == 'Succeeded'
                and matches(existing, desired)):
            log(f'  {args.deployment_name}: already matches all requested settings; unchanged')
            return 'unchanged'
    # Preserve writable settings not managed by this invocation, excluding GET-only properties.
    writable = ('model', 'modelProviderData', 'raiPolicyName', 'versionUpgradeOption',
                'dynamicThrottlingEnabled', 'spilloverDeploymentName', 'parentDeploymentName',
                'capacitySettings', 'priority', 'scaleSettings')
    for attempt in range(2):
        capacity = resolve_capacity(azure, location or row['location'], args, existing)
        desired = {'sku': {'name': args.sku['name'], 'capacity': capacity}, 'properties': properties}
        if (existing is not None
                and existing.get('properties', {}).get('provisioningState') == 'Succeeded'
                and matches(existing, desired)):
            log(f'  {args.deployment_name}: already matches quota-adjusted settings; unchanged')
            return 'unchanged'
        action = 'updating' if existing is not None else 'creating'
        log(f'  {args.deployment_name}: {action} (model={args.model["name"]}, '
            f'version={args.model["version"]}, format={args.model["format"]}, '
            f'sku={args.sku["name"]}, capacity={capacity})')
        preserved = {key: value for key, value in (existing or {}).get('properties', {}).items()
                     if key in writable}
        body = merge({'sku': (existing or {}).get('sku', {}), 'properties': preserved}, desired)
        try:
            azure.run('rest', '--method', 'put', '--url', url,
                      '--body', json.dumps(body, separators=(',', ':')), write=True)
        except DeploymentError as error:
            if attempt or 'InsufficientQuota' not in str(error):
                raise
            log('  Quota changed during deployment; refreshing availability and retrying once')
            existing = azure.run('rest', '--method', 'get', '--url', url, missing_ok=True)
            continue
        if not azure.dry_run:
            wait_for_deployment(azure, url, args, desired)
            log(f'  {args.deployment_name}: Succeeded; effective settings verified')
        return action


def process_subscription(row, args):
    azure = Azure(row['subscription_id'], args.dry_run)
    if args.direct or args.delete:
        group, account, _ = resource_names(row, args)
        location = row.get('location')
    else:
        ensure_providers(azure)
        group, account, location = ensure_resources(azure, row, args)
    return reconcile_deployment(azure, row, group, account, args, location)


def main(argv=None):
    args = parse_args(argv)
    try:
        rows = read_subscriptions(args.input, direct=args.direct, delete=args.delete)
        if not rows:
            raise DeploymentError('No subscriptions found in CSV')
        if shutil.which('az') is None:
            raise DeploymentError('Missing required command: az')
        operation = 'deletion' if args.delete else 'deployment'
        log(f'=== Single-model {operation}: {args.deployment_name} ===')
        log(f'Input: {args.input}; subscriptions: {len(rows)}; '
            f'direct: {args.direct}; dry-run: {args.dry_run}')
        for row in rows:
            log(f'  - {row["subscription_name"]} ({row["subscription_id"]})')
        if not args.force and not args.dry_run:
            if args.delete:
                print(f'Delete deployment {args.deployment_name} from {len(rows)} subscription(s)?', file=sys.stderr)
            print('Press Enter to continue, or Ctrl+C to abort...', file=sys.stderr, flush=True)
            if not sys.stdin.readline():
                raise DeploymentError('Confirmation cancelled; use --force for non-interactive execution')
        failed = 0
        for row in rows:
            log(f'=== Processing: {row["subscription_name"]} ===')
            try:
                process_subscription(row, args)
            except DeploymentError as error:
                failed += 1
                log(f'  ERROR: {row["subscription_name"]}: {error}')
        log(f'=== {"Dry run" if args.dry_run else operation.capitalize()} complete: '
            f'{len(rows) - failed} succeeded, {failed} failed ===')
        return 1 if failed else 0
    except (OSError, csv.Error, DeploymentError) as error:
        log(f'ERROR: {error}')
        return 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        log('Interrupted; rerun with the same arguments to reconcile resources')
        sys.exit(130)
