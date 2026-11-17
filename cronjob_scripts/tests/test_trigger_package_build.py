import unittest

from cronjob_scripts.trigger_package_build import is_valid_crate_name


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
