import unittest
from unittest import mock

from cronjob_scripts import trigger_package_build
from cronjob_scripts.trigger_package_build import (
    QueueInfo,
    is_valid_crate_name,
    trigger_for_target,
)
from cronjob_scripts.types import CrateAndMaybeVersion


class TestIsValidCrateName(unittest.TestCase):
    def test_valid(self):
        for name in ["ripgrep", "cargo-quickinstall", "serde_json", "a", "x" * 64]:
            self.assertTrue(is_valid_crate_name(name), name)

    def test_invalid(self):
        for name in [
            "",
            "-rf",
            "../ripgrep",
            "ab/cd",
            "foo bar",
            'foo"bar',
            "foo\nbar",
            "foo$(id)",
            "x" * 65,
            "café",
        ]:
            self.assertFalse(is_valid_crate_name(name), repr(name))


class TestTriggerForTarget(unittest.TestCase):
    def setUp(self):
        patches = {
            "get_current_version_if_unbuilt": mock.Mock(
                return_value={"name": "ripgrep", "vers": "15.1.0", "features": {}}
            ),
            "get_repo_url": mock.Mock(return_value="https://github.com/o/r"),
            "get_branch": mock.Mock(return_value="main"),
            "subprocess": mock.Mock(),
        }
        for name, value in patches.items():
            patcher = mock.patch.object(trigger_package_build, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.run_mock = patches["subprocess"].run

    def queue(self, type, target="x86_64-unknown-linux-gnu"):
        return QueueInfo(
            type=type,
            target=target,
            queue=[CrateAndMaybeVersion(crate="ripgrep", version=None)],
        )

    def test_triggers_once_per_run(self):
        # "requested" has everything in "failed", so a run sees a crate twice.
        triggered = set()
        trigger_for_target(self.queue("failed"), 0, triggered)
        trigger_for_target(self.queue("requested"), 0, triggered)
        self.assertEqual(self.run_mock.call_count, 1)
        self.assertEqual(triggered, {("ripgrep", "15.1.0", "x86_64-unknown-linux-gnu")})

    def test_triggers_each_target(self):
        triggered = set()
        for target in ["x86_64-unknown-linux-gnu", "aarch64-apple-darwin"]:
            trigger_for_target(self.queue("failed", target), 0, triggered)
        self.assertEqual(self.run_mock.call_count, 2)
        self.assertEqual(
            triggered,
            {
                ("ripgrep", "15.1.0", "x86_64-unknown-linux-gnu"),
                ("ripgrep", "15.1.0", "aarch64-apple-darwin"),
            },
        )
