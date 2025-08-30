use cargo_quickinstall::*;
use std::process;

/// Tests installation of cargo-update.
///
/// A prebuilt package of cargo-update version 18.0.0 for Linux x86_64 is known to
/// exist.  This should lead to a successful quickinstall.
#[test]
fn quickinstall_for_cargo_update() {
    let tmp_cargo_home_dir = mktemp::Temp::new_dir().unwrap();

    let tmp_cargo_bin_dir = tmp_cargo_home_dir.as_path().join("bin");
    std::fs::create_dir(&tmp_cargo_bin_dir).unwrap();

    std::env::set_var("CARGO_HOME", tmp_cargo_home_dir.as_path());

    let crate_details = CrateDetails {
        crate_name: "cargo-update".to_string(),
        version: "18.0.0".to_string(),
        target: get_target_triple().unwrap(),
    };
    let do_not_fallback_on_cargo_install = false;

    let result = install_crate_curl(&crate_details, do_not_fallback_on_cargo_install);

    assert!(result.is_ok(), "{}", result.err().unwrap());

    let mut cargo_update_path = tmp_cargo_bin_dir;
    cargo_update_path.push("cargo-install-update-config");

    assert!(cargo_update_path.is_file());

    std::process::Command::new(cargo_update_path)
        .arg("-V")
        .output_checked_status()
        .unwrap();
}

/// Tests dry run for cargo-update.
///
/// A prebuilt package of cargo-update version 18.0.0 for Linux x86_64 is known to
/// exist.
#[test]
fn do_dry_run_for_cargo_update() {
    let crate_details = CrateDetails {
        crate_name: "cargo-update".to_string(),
        version: "18.0.0".to_string(),
        target: "x86_64-unknown-linux-gnu".to_string(),
    };

    let result = do_dry_run_curl(&crate_details, false).unwrap();

    let expected_prefix = concat!("curl --user-agent \"cargo-quickinstall/", env!("CARGO_PKG_VERSION"), " client (alsuren@gmail.com)\" --location --silent --show-error --fail \"https://github.com/cargo-bins/cargo-quickinstall/releases/download/cargo-update-18.0.0/cargo-update-18.0.0-x86_64-unknown-linux-gnu.tar.gz\" | tar -xzvvf -");
    assert_eq!(&result[..expected_prefix.len()], expected_prefix);
}

/// Tests dry run for a non-existent package.
#[test]
fn do_dry_run_for_nonexistent_package() {
    let crate_details = CrateDetails {
        crate_name: "nonexisting_crate_12345".to_string(),
        version: "99".to_string(),
        target: "unknown".to_string(),
    };

    let result = do_dry_run_curl(&crate_details, true).unwrap();

    let expected = "cargo install nonexisting_crate_12345 --version 99";
    assert_eq!(expected, &result);
}

#[test]
fn test_get_latest_version() {
    const CRATE_NAME: &str = "cargo-quickinstall";

    let process::Output { status, stdout, .. } = process::Command::new("cargo")
        .args(["info", CRATE_NAME])
        .stderr(process::Stdio::inherit())
        .current_dir("../..")
        .output()
        .unwrap();
    assert!(status.success());

    let stdout = String::from_utf8_lossy(&stdout);
    let version = stdout
        .lines()
        .find_map(|line| line.strip_prefix("version: "))
        .unwrap();

    assert_eq!(get_latest_version(CRATE_NAME).unwrap(), version);
}
