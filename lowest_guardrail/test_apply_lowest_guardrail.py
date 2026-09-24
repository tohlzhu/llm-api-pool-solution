import contextlib
import io
import sys
import unittest
from unittest.mock import patch

import apply_lowest_guardrail as guardrail


class ManagementGroupSubscriptionTests(unittest.TestCase):
    def test_extracts_subscriptions_from_nested_management_groups(self) -> None:
        management_group = {
            "id": "/providers/Microsoft.Management/managementGroups/root",
            "type": "Microsoft.Management/managementGroups",
            "name": "root",
            "displayName": "Root",
            "tenantId": "tenant-id",
            "children": [
                {
                    "id": "/subscriptions/sub-direct",
                    "type": "/subscriptions",
                    "name": "sub-direct",
                    "displayName": "Direct subscription",
                    "tenantId": "tenant-id",
                    "children": None,
                },
                {
                    "id": "/providers/Microsoft.Management/managementGroups/child",
                    "type": "Microsoft.Management/managementGroups",
                    "name": "child",
                    "displayName": "Child",
                    "tenantId": "tenant-id",
                    "children": [
                        {
                            "id": "/subscriptions/sub-nested",
                            "type": "/subscriptions",
                            "name": "sub-nested",
                            "displayName": "Nested subscription",
                            "tenantId": "tenant-id",
                            "children": None,
                        }
                    ],
                },
            ],
        }

        extract = getattr(
            guardrail, "subscription_ids_from_management_group", lambda _: []
        )

        self.assertEqual(extract(management_group), ["sub-direct", "sub-nested"])

    @patch.object(guardrail, "run_az")
    def test_selects_only_enabled_cli_visible_subscriptions(self, run_az) -> None:
        management_group = {
            "id": "/providers/Microsoft.Management/managementGroups/root",
            "type": "Microsoft.Management/managementGroups",
            "name": "root",
            "displayName": "Root",
            "tenantId": "tenant-id",
            "children": [
                {
                    "id": "/subscriptions/sub-enabled",
                    "type": "/subscriptions",
                    "name": "sub-enabled",
                    "displayName": "Enabled",
                    "tenantId": "tenant-id",
                    "children": None,
                },
                {
                    "id": "/subscriptions/sub-disabled",
                    "type": "/subscriptions",
                    "name": "sub-disabled",
                    "displayName": "Disabled",
                    "tenantId": "tenant-id",
                    "children": None,
                },
                {
                    "id": "/subscriptions/sub-invisible",
                    "type": "/subscriptions",
                    "name": "sub-invisible",
                    "displayName": "Invisible",
                    "tenantId": "tenant-id",
                    "children": None,
                },
            ],
        }
        run_az.side_effect = [
            management_group,
            [
                {"id": "sub-enabled", "state": "Enabled"},
                {"id": "sub-disabled", "state": "Disabled"},
            ],
        ]
        select = getattr(guardrail, "management_group_subscriptions", lambda _: [])

        self.assertEqual(select("root"), ["sub-enabled"])

    @patch.object(guardrail, "run_az")
    def test_management_group_lookup_failure_does_not_fall_back(self, run_az) -> None:
        expected = guardrail.AzureCliError(("az",), 1, "access denied")
        run_az.side_effect = expected

        with self.assertRaises(guardrail.AzureCliError) as error:
            guardrail.management_group_subscriptions("root")

        self.assertIs(error.exception, expected)
        run_az.assert_called_once()


class ManagementGroupArgumentTests(unittest.TestCase):
    def test_accepts_repeatable_management_group_target(self) -> None:
        argv = [
            "apply_lowest_guardrail.py",
            "--management-group",
            "parent",
            "--management-group",
            "other",
        ]

        with patch.object(sys, "argv", argv):
            try:
                args = guardrail.parse_args()
            except SystemExit as error:
                self.fail(f"--management-group was rejected with exit {error.code}")

        self.assertEqual(args.management_group, ["parent", "other"])

    def test_requires_yes_when_applying_to_management_group(self) -> None:
        argv = [
            "apply_lowest_guardrail.py",
            "--management-group",
            "parent",
            "--apply",
        ]

        with (
            patch.object(sys, "argv", argv),
            contextlib.redirect_stderr(io.StringIO()),
            self.assertRaises(SystemExit) as error,
        ):
            guardrail.parse_args()

        self.assertEqual(error.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
