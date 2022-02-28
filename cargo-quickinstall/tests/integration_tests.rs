use cargo_quickinstall::*;

#[test]
fn do_dry_run_for_nonexistent_package() {
    let crate_details = CrateDetails {
        crate_name: "nonexisting_crate_12345".to_string(),
        version: "99".to_string(),
        target: "unknown".to_string(),
    };

    let result = do_dry_run(&crate_details);

    let expected = r#""cargo" "install" "nonexisting_crate_12345" "--version" "99""#;
    assert_eq!(expected, &result);
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

    std::env::set_var("CARGO_HOME", "/tmp/mock-cargo-root");
    let result = do_dry_run(&crate_details);

    let expected = r#""curl" "--user-agent" "cargo-quickinstall client (alsuren@gmail.com)" "--location" "--silent" "--show-error" "--fail" "https://github.com/alsuren/cargo-quickinstall/releases/download/ripgrep-13.0.0-x86_64-unknown-linux-gnu/ripgrep-13.0.0-x86_64-unknown-linux-gnu.tar.gz" | "tar" "-xzvvf" "-" "-C" "/tmp/mock-cargo-root/bin""#;
    assert_eq!(expected, &result);
}
