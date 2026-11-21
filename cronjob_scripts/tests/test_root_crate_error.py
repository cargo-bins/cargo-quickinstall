import unittest

from cronjob_scripts.root_crate_error import root_crate_error


def log(text: str) -> list[str]:
    """A job log, with GitHub's timestamps."""
    return [f"2026-11-21T05:00:00.0000000Z {line}\n" for line in text.splitlines()]


STUB = r"""
  Installing rg v0.2.2
   Compiling rg v0.2.2
error: you meant to install ripgrep: type `cargo install ripgrep`
 --> /home/runner/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/rg-0.2.2/main.rs:1:1
  |
1 | compile_error!("you meant to install ripgrep: type `cargo install ripgrep`");
error: could not compile `rg` (bin "rg") due to 1 previous error
"""

UNIX_ONLY = r"""
  Installing codeberg-cli v0.5.5
error[E0433]: cannot find `unix` in `os`
 --> C:\Users\runneradmin\.cargo\registry\src\index.crates.io-1949cf8c6b5b557f\codeberg-cli-0.5.5\src\actions\auth\login.rs:2:14
error: could not compile `codeberg-cli` (lib) due to 2 previous errors
"""

DEPENDENCY = r"""
  Installing cpx v0.2.1
error[E0433]: cannot find `unix` in `os`
  --> C:\Users\runneradmin\.cargo\registry\src\index.crates.io-1949cf8c6b5b557f\xattr-1.6.1\src\lib.rs:35:14
error: could not compile `xattr` (lib) due to 1 previous error
"""

LINKER = r"""
  Installing foo v1.0.0
warning: unused import: `bar`
 --> /home/runner/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/foo-1.0.0/src/main.rs:1:5
error: linking with `cc` failed: exit status: 1
  = note: undefined reference to `SSL_new'
error: could not compile `foo` (bin "foo") due to 1 previous error
"""


class TestRootCrateError(unittest.TestCase):
    def test_stub(self):
        self.assertEqual(
            root_crate_error("rg", "0.2.2", log(STUB)),
            "error: you meant to install ripgrep: type `cargo install ripgrep`",
        )

    def test_windows_path(self):
        self.assertEqual(
            root_crate_error("codeberg-cli", "0.5.5", log(UNIX_ONLY)),
            "error[E0433]: cannot find `unix` in `os`",
        )

    def test_error_in_a_dependency(self):
        self.assertIsNone(root_crate_error("cpx", "0.2.1", log(DEPENDENCY)))

    def test_warning_in_the_crate_then_linker_error(self):
        self.assertIsNone(root_crate_error("foo", "1.0.0", log(LINKER)))

    def test_other_version(self):
        self.assertIsNone(root_crate_error("rg", "0.2.3", log(STUB)))

    def test_only_the_last_attempt_counts(self):
        # The `--locked` build failed in the crate, the build without it in
        # the linker.
        attempts = STUB.replace("Installing rg v0.2.2", "Installing foo v1.0.0")
        attempts = attempts.replace("rg-0.2.2", "foo-1.0.0") + LINKER
        self.assertIsNone(root_crate_error("foo", "1.0.0", log(attempts)))
        self.assertIsNotNone(
            root_crate_error("foo", "1.0.0", log(LINKER + attempts.split(LINKER)[0]))
        )


if __name__ == "__main__":
    unittest.main()
