from pathlib import Path
import unittest


from cronjob_scripts.architectures import TARGET_ARCH_TO_BUILD_OS


class TestMyScript(unittest.TestCase):
    def test_supported_targets(self):
        with open(
            Path(__file__).resolve().parent.parent.parent.joinpath("supported-targets"),
            "r",
        ) as file:
            supported_targets = [word for word in file.read().split() if word]

        assert set(TARGET_ARCH_TO_BUILD_OS.keys()) == set(
            supported_targets
        ), "please keep /supported-targets and TARGET_ARCH_TO_BUILD_OS in sync"
