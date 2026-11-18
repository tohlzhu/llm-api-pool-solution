import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'deploy-single-model.py'
spec = importlib.util.spec_from_file_location('deploy_single_model', SCRIPT)
deploy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deploy)


class SingleModelTests(unittest.TestCase):
    def setUp(self):
        self.args = deploy.parse_args([
            '--model-info', 'custom-deployment|new-model|2026-09-22|OpenAI|GlobalStandard|1000000',
            '--force',
        ])
        self.row = {
            'subscription_id': 'sub-1', 'subscription_name': 'existing-sub',
            'prefix': 'legacy', 'model_type': 'unknown-group', 'location': 'japaneast',
        }
        self.existing = {
            'sku': copy.deepcopy(self.args.sku),
            'properties': {'model': copy.deepcopy(self.args.model), 'provisioningState': 'Succeeded'},
        }
        self.azure = deploy.Azure('sub-1', False)
        self.logs = contextlib.redirect_stderr(io.StringIO())
        self.logs.__enter__()
        self.addCleanup(self.logs.__exit__, None, None, None)
        capacity = patch.object(deploy, 'resolve_capacity', side_effect=lambda azure, location, args, old: args.sku['capacity'])
        capacity.start()
        self.addCleanup(capacity.stop)

    def test_only_requested_deployment_is_read_and_matching_settings_are_skipped(self):
        with patch.object(self.azure, 'run', return_value=self.existing) as run:
            result = deploy.reconcile_deployment(self.azure, self.row, 'group', 'account', self.args)
        self.assertEqual(result, 'unchanged')
        self.assertEqual(run.call_count, 1)
        self.assertIn('/deployments/custom-deployment?', run.call_args.args[4])
        self.assertNotIn('list', run.call_args.args)

    def test_reconciles_every_model_field_and_sku_and_preserves_unmanaged_settings(self):
        for part, field, wrong in (
            ('sku', 'capacity', 2), ('sku', 'name', 'Standard'),
            ('model', 'name', 'old-model'), ('model', 'version', 'old-version'),
            ('model', 'format', 'DeepSeek'),
        ):
            with self.subTest(part=part, field=field):
                old = copy.deepcopy(self.existing)
                target = old['properties']['model'] if part == 'model' else old['sku']
                target[field] = wrong
                old['properties'].update({'raiPolicyName': 'custom-policy', 'dynamicThrottlingEnabled': True})
                with patch.object(self.azure, 'run', side_effect=[old, {}, self.existing]) as run:
                    result = deploy.reconcile_deployment(self.azure, self.row, 'group', 'account', self.args)
                self.assertEqual(result, 'updating')
                body = json.loads(run.call_args_list[1].args[-1])
                self.assertEqual(body['sku'], self.args.sku)
                self.assertEqual(body['properties']['model'], self.args.model)
                self.assertEqual(body['properties']['raiPolicyName'], 'custom-policy')
                self.assertTrue(body['properties']['dynamicThrottlingEnabled'])
                self.assertNotIn('provisioningState', body['properties'])

    def test_creates_missing_deployment_with_exact_raw_capacity(self):
        with patch.object(self.azure, 'run', side_effect=[None, {}, self.existing]) as run:
            result = deploy.reconcile_deployment(self.azure, self.row, 'group', 'account', self.args)
        self.assertEqual(result, 'creating')
        body = json.loads(run.call_args_list[1].args[-1])
        self.assertEqual(body['sku']['capacity'], 1000000)
        self.assertTrue(run.call_args_list[1].kwargs['write'])

    def test_ensures_missing_resource_hierarchy_and_uses_name_overrides(self):
        args = copy.deepcopy(self.args)
        args.resource_group, args.account_name, args.project_name = 'legacy-rg', 'legacy-account', 'legacy-project'
        responses = [None, {}, None, [], {'location': 'japaneast'}, None, None, {}]
        with patch.object(self.azure, 'run', side_effect=responses) as run:
            group, account, location = deploy.ensure_resources(self.azure, self.row, args)
        self.assertEqual((group, account, location), ('legacy-rg', 'legacy-account', 'japaneast'))
        writes = [call.args for call in run.call_args_list if call.kwargs.get('write')]
        self.assertEqual([call[:3] for call in writes], [
            ('group', 'create', '--name'), ('cognitiveservices', 'account', 'create'),
            ('cognitiveservices', 'account', 'project'),
        ])
        self.assertIn('legacy-project', writes[-1])
        self.assertNotIn('account', writes[0])

    def test_reuses_intermediate_resources_and_original_default_names(self):
        foundry = {'location': 'eastus2', 'properties': {'allowProjectManagement': True}}
        with patch.object(self.azure, 'run', side_effect=[{}, foundry, {}]) as run:
            self.assertEqual(deploy.ensure_resources(self.azure, self.row, self.args),
                             ('rg-foundry', 'fdry-existing-sub', 'eastus2'))
        self.assertEqual(run.call_count, 3)
        self.assertIn('proj-existing-sub', run.call_args.args)
        self.assertFalse(any(call.kwargs.get('write') for call in run.call_args_list))

    def test_additional_properties_and_anthropic_csv_metadata_ignore_model_type(self):
        self.args.model['format'] = 'Anthropic'
        self.args.deployment_properties = {
            'versionUpgradeOption': 'NoAutoUpgrade', 'model': {'source': 'custom-source'},
            'modelProviderData': {'organizationName': 'Explicit organization'},
        }
        self.row.update({'anthropic-org': 'CSV organization', 'anthropic-industry': 'Manufacturing',
                         'anthropic-country': 'SG'})
        with patch.object(self.azure, 'run') as run:
            properties = deploy.desired_properties(self.azure, self.row, self.args)
        self.assertEqual(properties['modelProviderData'], {
            'organizationName': 'Explicit organization', 'industry': 'Manufacturing', 'countryCode': 'SG',
        })
        self.assertEqual(properties['model']['source'], 'custom-source')
        self.assertEqual(properties['versionUpgradeOption'], 'NoAutoUpgrade')
        run.assert_not_called()

    def test_explicit_extra_properties_are_reconciled(self):
        self.args.deployment_properties = {'versionUpgradeOption': 'NoAutoUpgrade'}
        updated = copy.deepcopy(self.existing)
        updated['properties']['versionUpgradeOption'] = 'NoAutoUpgrade'
        with patch.object(self.azure, 'run', side_effect=[self.existing, {}, updated]) as run:
            result = deploy.reconcile_deployment(self.azure, self.row, 'group', 'account', self.args)
        self.assertEqual(result, 'updating')
        body = json.loads(run.call_args_list[1].args[-1])
        self.assertEqual(body['properties']['versionUpgradeOption'], 'NoAutoUpgrade')

    def test_soft_deleted_accounts_are_not_automatically_purged(self):
        responses = [{}, None, [{'name': 'fdry-existing-sub'}]]
        with patch.object(self.azure, 'run', side_effect=responses) as run:
            with self.assertRaisesRegex(deploy.DeploymentError, 'soft-deleted'):
                deploy.ensure_resources(self.azure, self.row, self.args)
        self.assertFalse(any(call.kwargs.get('write') for call in run.call_args_list))

    def test_in_progress_deployment_is_waited_for_then_skipped(self):
        pending = copy.deepcopy(self.existing)
        pending['properties']['provisioningState'] = 'Updating'
        with patch.object(self.azure, 'run', side_effect=[pending, self.existing]) as run:
            result = deploy.reconcile_deployment(self.azure, self.row, 'group', 'account', self.args)
        self.assertEqual(result, 'unchanged')
        self.assertFalse(any(call.kwargs.get('write') for call in run.call_args_list))

    def test_provisioning_failure_and_unapplied_settings_are_not_success(self):
        failed = copy.deepcopy(self.existing)
        failed['properties']['provisioningState'] = 'Failed'
        with patch.object(self.azure, 'run', side_effect=[None, {}, failed]):
            with self.assertRaisesRegex(deploy.DeploymentError, 'Failed'):
                deploy.reconcile_deployment(self.azure, self.row, 'group', 'account', self.args)
        with patch.object(self.azure, 'run', return_value=self.existing), \
                patch.object(deploy.time, 'monotonic', side_effect=[0, 1000]):
            with self.assertRaisesRegex(deploy.DeploymentError, 'timed out'):
                deploy.wait_for_deployment(self.azure, 'url', self.args, {'sku': {'capacity': 1}})

    def test_only_not_found_is_treated_as_missing_and_default_account_is_never_changed(self):
        for error, missing in (('ERROR: (ResourceNotFound) missing', True),
                               ('ERROR: Not Found({"error":{"code":"NotFound"}})', True),
                               ('ERROR: (AuthorizationFailed) forbidden', False)):
            result = subprocess.CompletedProcess([], 3, '', error)
            with self.subTest(error=error), patch.object(deploy.subprocess, 'run', return_value=result) as run:
                if missing:
                    self.assertIsNone(self.azure.run('group', 'show', '--name', 'group', missing_ok=True))
                else:
                    with self.assertRaisesRegex(deploy.DeploymentError, 'AuthorizationFailed'):
                        self.azure.run('group', 'show', '--name', 'group', missing_ok=True)
                command = run.call_args.args[0]
                self.assertEqual(command[command.index('--subscription') + 1], 'sub-1')
                self.assertNotIn('set', command)

    def test_dry_run_never_executes_writes(self):
        self.azure.dry_run = True
        with patch.object(deploy.subprocess, 'run') as run:
            self.azure.run('rest', '--method', 'put', '--url', 'url', '--body', '{}', write=True)
        run.assert_not_called()

    def test_direct_mode_probes_deployment_without_any_intermediate_resource_calls(self):
        self.args.direct = True
        with patch.object(deploy, 'ensure_providers') as providers, \
                patch.object(deploy, 'ensure_resources') as resources, \
                patch.object(deploy.Azure, 'run', return_value=self.existing) as run:
            result = deploy.process_subscription(self.row, self.args)
        self.assertEqual(result, 'unchanged')
        providers.assert_not_called()
        resources.assert_not_called()
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args.args[:3], ('rest', '--method', 'get'))
        self.assertIn('/accounts/fdry-existing-sub/deployments/custom-deployment?', run.call_args.args[4])

    def test_normal_mode_uses_existing_account_location_for_quota(self):
        with patch.object(deploy, 'ensure_providers') as providers, \
                patch.object(deploy, 'ensure_resources', return_value=('group', 'account', 'eastus2')), \
                patch.object(deploy, 'reconcile_deployment', return_value='unchanged') as reconcile:
            deploy.process_subscription(self.row, self.args)
        providers.assert_called_once()
        self.assertEqual(reconcile.call_args.args[-1], 'eastus2')

    def test_quota_race_refreshes_capacity_and_retries_once(self):
        verified = copy.deepcopy(self.existing)
        verified['sku']['capacity'] = 600
        responses = [None, deploy.DeploymentError('InsufficientQuota'), None, {}, verified]
        with patch.object(deploy, 'resolve_capacity', side_effect=[1000, 600]) as capacity, \
                patch.object(self.azure, 'run', side_effect=responses) as run:
            result = deploy.reconcile_deployment(self.azure, self.row, 'group', 'account', self.args)
        self.assertEqual(result, 'creating')
        self.assertEqual(capacity.call_count, 2)
        bodies = [json.loads(call.args[-1]) for call in run.call_args_list if call.kwargs.get('write')]
        self.assertEqual([body['sku']['capacity'] for body in bodies], [1000, 600])

    def test_non_quota_errors_are_not_retried_and_quota_retries_are_bounded(self):
        for responses, expected_calls in (
            ([None, deploy.DeploymentError('InvalidResourceProperties')], 2),
            ([None, deploy.DeploymentError('InsufficientQuota'), None,
              deploy.DeploymentError('InsufficientQuota')], 4),
        ):
            with self.subTest(responses=responses), patch.object(self.azure, 'run', side_effect=responses) as run:
                with self.assertRaises(deploy.DeploymentError):
                    deploy.reconcile_deployment(self.azure, self.row, 'group', 'account', self.args)
                self.assertEqual(run.call_count, expected_calls)

    def test_csv_quotes_bom_crlf_and_missing_model_type(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'subscriptions.csv'
            path.write_bytes(b'\xef\xbb\xbfsubscription_id,subscription_name,prefix,location,anthropic-org\r\n'
                             b'sub-1,existing-sub,legacy,japaneast,"Example, Inc."\r\n')
            rows = deploy.read_subscriptions(path)
        self.assertEqual(rows[0]['anthropic-org'], 'Example, Inc.')
        self.assertEqual(rows[0]['subscription_id'], 'sub-1')

    def test_direct_csv_does_not_require_unused_prefix(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'subscriptions.csv'
            path.write_text('subscription_id,subscription_name,location\nsub-1,existing-sub,japaneast\n')
            self.assertEqual(len(deploy.read_subscriptions(path, direct=True)), 1)
            with self.assertRaisesRegex(deploy.DeploymentError, 'prefix'):
                deploy.read_subscriptions(path)

    def test_batch_continues_after_failure_and_returns_nonzero(self):
        second = dict(self.row, subscription_id='sub-2')
        with patch.object(deploy, 'read_subscriptions', return_value=[self.row, second]), \
                patch.object(deploy.shutil, 'which', return_value='/mock/az'), \
                patch.object(deploy, 'process_subscription', side_effect=[deploy.DeploymentError('quota'), 'unchanged']) as process:
            result = deploy.main(['--model-info', self.args.model_info, '--force'])
        self.assertEqual(result, 1)
        self.assertEqual(process.call_count, 2)

    def test_confirmation_eof_does_not_deploy(self):
        with patch.object(deploy, 'read_subscriptions', return_value=[self.row]), \
                patch.object(deploy.shutil, 'which', return_value='/mock/az'), \
                patch.object(deploy.sys, 'stdin', io.StringIO('')), \
                patch.object(deploy, 'process_subscription') as process:
            result = deploy.main(['--model-info', self.args.model_info])
        self.assertEqual(result, 1)
        process.assert_not_called()

    def test_python_entrypoint_rejects_bad_model_info_before_calling_azure(self):
        for info in ('only|two', 'd|m|v|OpenAI|GlobalStandard|1|extra',
                     'd|m||OpenAI|GlobalStandard|1', 'd|m|v|OpenAI|GlobalStandard|-1'):
            with self.subTest(info=info):
                result = subprocess.run([sys.executable, str(SCRIPT), '--model-info', info],
                                        text=True, capture_output=True, check=False)
                self.assertEqual(result.returncode, 2)
                self.assertIn('error:', result.stderr)


class DeleteDeploymentTests(unittest.TestCase):
    def setUp(self):
        self.args = deploy.parse_args(['--delete', '--model-info', 'target-deployment', '--force'])
        self.row = {'subscription_id': 'sub-1', 'subscription_name': 'sub'}
        self.existing = {'properties': {'provisioningState': 'Succeeded'}}
        self.logs = contextlib.redirect_stderr(io.StringIO())
        self.logs.__enter__()
        self.addCleanup(self.logs.__exit__, None, None, None)

    def test_missing_deployment_skips_without_infrastructure_or_quota_queries(self):
        with patch.object(deploy.Azure, 'run', return_value=None) as run, \
                patch.object(deploy, 'ensure_providers') as providers, \
                patch.object(deploy, 'ensure_resources') as resources, \
                patch.object(deploy, 'resolve_capacity') as capacity, \
                patch.object(deploy, 'desired_properties') as properties:
            result = deploy.process_subscription(self.row, self.args)
        self.assertEqual(result, 'unchanged')
        providers.assert_not_called()
        resources.assert_not_called()
        capacity.assert_not_called()
        properties.assert_not_called()
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args.args[:3], ('rest', '--method', 'get'))
        self.assertIn('/accounts/fdry-sub/deployments/target-deployment?', run.call_args.args[4])
        self.assertTrue(run.call_args.kwargs['missing_ok'])

    def test_existing_deployment_is_deleted_then_polled_until_absent(self):
        deleting = {'properties': {'provisioningState': 'Deleting'}}
        with patch.object(deploy.Azure, 'run', side_effect=[self.existing, None, deleting, None]) as run, \
                patch.object(deploy.time, 'sleep') as sleep:
            result = deploy.process_subscription(self.row, self.args)
        self.assertEqual(result, 'deleted')
        self.assertEqual([call.args[2] for call in run.call_args_list], ['get', 'delete', 'get', 'get'])
        deletion = run.call_args_list[1]
        self.assertTrue(deletion.kwargs['write'])
        self.assertTrue(deletion.kwargs['missing_ok'])
        self.assertEqual(deletion.args[4], run.call_args_list[0].args[4])
        sleep.assert_called_once()

    def test_failed_deployments_can_be_deleted_without_waiting_for_success(self):
        failed = {'properties': {'provisioningState': 'Failed'}}
        with patch.object(deploy.Azure, 'run', side_effect=[failed, None, None]) as run:
            self.assertEqual(deploy.process_subscription(self.row, self.args), 'deleted')
        self.assertEqual(run.call_args_list[1].args[2], 'delete')

    def test_deletion_in_progress_is_only_waited_for(self):
        deleting = {'properties': {'provisioningState': 'Deleting'}}
        with patch.object(deploy.Azure, 'run', side_effect=[deleting, None]) as run:
            self.assertEqual(deploy.process_subscription(self.row, self.args), 'deleted')
        self.assertEqual([call.args[2] for call in run.call_args_list], ['get', 'get'])

    def test_delete_dry_run_never_executes_a_write_or_polls_for_absence(self):
        self.args.dry_run = True
        response = subprocess.CompletedProcess([], 0, json.dumps(self.existing), '')
        with patch.object(deploy.subprocess, 'run', return_value=response) as run:
            self.assertEqual(deploy.process_subscription(self.row, self.args), 'deleting')
        self.assertEqual(run.call_count, 1)
        command = run.call_args.args[0]
        self.assertEqual(command[command.index('--method') + 1], 'get')
        self.assertEqual(command[command.index('--subscription') + 1], 'sub-1')

    def test_delete_timeout_is_not_reported_as_success(self):
        with patch.object(deploy.Azure, 'run', side_effect=[self.existing, None, self.existing]), \
                patch.object(deploy.time, 'monotonic', side_effect=[0, 1000]):
            with self.assertRaisesRegex(deploy.DeploymentError, 'timed out waiting for deletion'):
                deploy.process_subscription(self.row, self.args)

    def test_delete_permission_failure_is_not_treated_as_missing(self):
        with patch.object(deploy.Azure, 'run', side_effect=[self.existing, deploy.DeploymentError('AuthorizationFailed')]) as run:
            with self.assertRaisesRegex(deploy.DeploymentError, 'AuthorizationFailed'):
                deploy.process_subscription(self.row, self.args)
        self.assertEqual(run.call_count, 2)

    def test_delete_accepts_full_model_info_but_does_not_use_model_metadata(self):
        args = deploy.parse_args([
            '--delete', '--model-info', 'target-deployment|unused|unused|Anthropic|unused|1000',
        ])
        with patch.object(deploy.Azure, 'run', return_value=None) as run:
            self.assertEqual(deploy.process_subscription(self.row, args), 'unchanged')
        self.assertEqual(run.call_count, 1)

    def test_delete_csv_does_not_require_unused_prefix_or_location(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'subscriptions.csv'
            path.write_text('subscription_id,subscription_name\nsub-1,sub\n')
            self.assertEqual(deploy.read_subscriptions(path, delete=True), [self.row])


class QuotaCapacityTests(unittest.TestCase):
    def setUp(self):
        self.args = deploy.parse_args([
            '--model-info', 'deployment|model|version|OpenAI|GlobalStandard|1000000', '--direct', '--force',
        ])
        self.azure = deploy.Azure('sub-1', False)
        self.metric = 'provider.shared-model-quota'
        self.catalog = [dict(self.args.model, skus=[{
            'name': 'GlobalStandard', 'usageName': self.metric,
            'capacity': {'maximum': 10000000, 'minimum': None, 'step': None, 'allowedValues': None},
        }])]
        self.usage = [{'name': self.metric, 'limit': 1000.0, 'currentValue': 400.0}]
        self.logs = contextlib.redirect_stderr(io.StringIO())
        self.logs.__enter__()
        self.addCleanup(self.logs.__exit__, None, None, None)

    def existing(self, capacity):
        return {'sku': {'name': 'GlobalStandard', 'capacity': capacity},
                'properties': {'model': copy.deepcopy(self.args.model), 'provisioningState': 'Succeeded'}}

    def resolve(self, existing=None):
        with patch.object(self.azure, 'run', side_effect=[self.catalog, self.usage]) as run:
            capacity = deploy.resolve_capacity(self.azure, 'japaneast', self.args, existing)
        return capacity, run

    def test_explicit_capacity_is_capped_using_metadata_metric_and_exact_usage_filter(self):
        capacity, run = self.resolve()
        self.assertEqual(capacity, 600)
        usage_call = run.call_args_list[1].args
        self.assertIn("name.value eq 'provider.shared-model-quota'", usage_call)
        self.assertEqual(self.args.sku['capacity'], 1000000)

    def test_capacity_can_be_omitted_or_empty_and_uses_all_available_quota(self):
        for suffix in ('', '|'):
            with self.subTest(suffix=suffix):
                self.args = deploy.parse_args([
                    '--model-info', 'deployment|model|version|OpenAI|GlobalStandard' + suffix,
                ])
                self.assertIsNone(self.args.sku['capacity'])
                self.assertEqual(self.resolve()[0], 600)

    def test_requested_capacity_below_available_quota_is_not_increased(self):
        self.args.sku['capacity'] = 200
        self.assertEqual(self.resolve()[0], 200)

    def test_current_capacity_is_reusable_without_double_counting_or_exceeding_limit(self):
        for used, old_capacity, expected in (
            (1000, 1000, 1000), (400, 200, 800), (1500, 1000, 500), (0, 1000, 1000),
        ):
            with self.subTest(used=used, old_capacity=old_capacity):
                self.usage[0]['currentValue'] = used
                self.assertEqual(self.resolve(self.existing(old_capacity))[0], expected)

    def test_current_capacity_field_takes_precedence_over_requested_sku_capacity(self):
        existing = self.existing(1000)
        existing['properties']['currentCapacity'] = 200
        self.assertEqual(self.resolve(existing)[0], 800)

    def test_different_quota_pool_does_not_credit_existing_capacity(self):
        existing = self.existing(400)
        existing['properties']['model']['name'] = 'old-model'
        old = copy.deepcopy(self.catalog[0])
        old['name'] = 'old-model'
        old['skus'][0]['usageName'] = 'different-quota-pool'
        self.catalog.append(old)
        self.assertEqual(self.resolve(existing)[0], 600)

    def test_different_versions_sharing_a_quota_pool_can_reuse_capacity(self):
        existing = self.existing(400)
        existing['properties']['model']['version'] = 'old-version'
        self.catalog.append(dict(copy.deepcopy(self.catalog[0]), version='old-version'))
        self.assertEqual(self.resolve(existing)[0], 1000)

    def test_sku_maximum_step_and_allowed_values_are_respected(self):
        for bounds, expected in (
            ({'maximum': 450}, 450),
            ({'minimum': 100, 'step': 100}, 600),
            ({'step': 250}, 500),
            ({'allowedValues': [100, 400, 700]}, 400),
        ):
            with self.subTest(bounds=bounds):
                self.catalog[0]['skus'][0]['capacity'] = bounds
                self.assertEqual(self.resolve()[0], expected)

    def test_no_quota_or_capacity_below_sku_minimum_fails_without_a_write(self):
        for used, bounds in ((1000, {}), (950, {'minimum': 100}), (1001, {})):
            with self.subTest(used=used), patch.object(self.azure, 'run') as run:
                self.usage[0]['currentValue'] = used
                self.catalog[0]['skus'][0]['capacity'] = bounds
                run.side_effect = [self.catalog, self.usage]
                with self.assertRaisesRegex(deploy.DeploymentError, 'No deployable capacity'):
                    deploy.resolve_capacity(self.azure, 'japaneast', self.args, None)
                self.assertFalse(any(call.kwargs.get('write') for call in run.call_args_list))

    def test_missing_metadata_or_unreliable_quota_is_not_silently_guessed(self):
        for responses in ([[]], [self.catalog, []],
                          [self.catalog, [{'name': self.metric, 'limit': None, 'currentValue': 0}]]):
            with self.subTest(responses=responses), patch.object(self.azure, 'run', side_effect=responses):
                with self.assertRaises(deploy.DeploymentError):
                    deploy.resolve_capacity(self.azure, 'japaneast', self.args, None)

    def test_different_subscription_limits_do_not_mutate_shared_requested_capacity(self):
        capacities = []
        for limit in (1000, 500):
            self.usage[0]['limit'] = limit
            capacities.append(self.resolve()[0])
        self.assertEqual(capacities, [600, 100])
        self.assertEqual(self.args.sku['capacity'], 1000000)

    def test_direct_create_probes_target_then_resolves_quota_and_writes_adjusted_capacity(self):
        row = {'subscription_id': 'sub-1', 'subscription_name': 'sub', 'location': 'japaneast'}
        verified = self.existing(600)
        responses = [None, self.catalog, self.usage, {}, verified]
        with patch.object(deploy.Azure, 'run', side_effect=responses) as run:
            result = deploy.process_subscription(row, self.args)
        self.assertEqual(result, 'creating')
        self.assertEqual(run.call_args_list[0].args[:3], ('rest', '--method', 'get'))
        writes = [call for call in run.call_args_list if call.kwargs.get('write')]
        self.assertEqual(len(writes), 1)
        self.assertEqual(json.loads(writes[0].args[-1])['sku']['capacity'], 600)


if __name__ == '__main__':
    unittest.main()
