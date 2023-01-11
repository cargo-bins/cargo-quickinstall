use cargo_quickinstall::*;

/// Tests installation of Ripgrep.
///
/// A prebuilt package of Ripgrep version 13.0.0 for Linux x86_64 is known to
/// exist.  This should lead to a successful quickinstall.
#[test]
fn quickinstall_for_ripgrep() {
    let tmp_cargo_home_dir = mktemp::Temp::new_dir().unwrap();
    let mut tmp_cargo_bin_dir = tmp_cargo_home_dir.to_path_buf();
    tmp_cargo_bin_dir.push("bin");
    std::fs::create_dir(tmp_cargo_bin_dir).unwrap();
    std::env::set_var("CARGO_HOME", tmp_cargo_home_dir.to_str().unwrap());

    let crate_details = CrateDetails {
        crate_name: "ripgrep".to_string(),
        version: "13.0.0".to_string(),
        target: "x86_64-unknown-linux-gnu".to_string(),
    };
    let do_not_fallback_on_cargo_install = false;

    let result = install_crate_curl(&crate_details, do_not_fallback_on_cargo_install);

    assert!(result.is_ok());
}

/// Tests dry run for Ripgrep.
///
/// A prebuilt package of Ripgrep version 13.0.0 for Linux x86_64 is known to
/// exist.
#[test]
fn do_dry_run_for_ripgrep() {
    let crate_details = CrateDetails {
        crate_name: "ripgrep".to_string(),
        version: "13.0.0".to_string(),
        target: "x86_64-unknown-linux-gnu".to_string(),
    };

    let result = do_dry_run_curl(&crate_details);

    let expected_prefix = r#""curl" "--user-agent" "cargo-quickinstall client (alsuren@gmail.com)" "--location" "--silent" "--show-error" "--fail" "https://github.com/cargo-bins/cargo-quickinstall/releases/download/ripgrep-13.0.0-x86_64-unknown-linux-gnu/ripgrep-13.0.0-x86_64-unknown-linux-gnu.tar.gz" | "tar" "-xzvvf" "-" "-C""#;
    assert!(result.starts_with(expected_prefix));
}

/// Tests dry run for a non-existent package.
#[test]
fn do_dry_run_for_nonexistent_package() {
    let crate_details = CrateDetails {
        crate_name: "nonexisting_crate_12345".to_string(),
        version: "99".to_string(),
        target: "unknown".to_string(),
    };

    let result = do_dry_run_curl(&crate_details);

    let expected = r#""cargo" "install" "nonexisting_crate_12345" "--version" "99""#;
    assert_eq!(expected, &result);
}
