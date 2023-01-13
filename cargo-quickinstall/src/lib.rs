//! Pre-built binary crate installer.
//!
//! Tries to install pre-built binary crates whenever possibles.  Falls back to
//! `cargo install` otherwise.

use std::process;
use tinyjson::JsonValue;

pub mod install_error;

use install_error::*;

mod command_ext;
pub use command_ext::{ChildWithCmd, CommandExt, CommandFormattable};

mod json_value_ext;
pub use json_value_ext::{JsonExtError, JsonKey, JsonValueExt};

mod utils;
pub use utils::utf8_to_string_lossy;

#[derive(Debug)]
pub struct CommandFailed {
    pub command: String,
    pub stdout: String,
    pub stderr: String,
}

#[derive(Clone)]
pub struct CrateDetails {
    pub crate_name: String,
    pub version: String,
    pub target: String,
}

pub fn get_cargo_binstall_version() -> Option<String> {
    let output = std::process::Command::new("cargo")
        .args(["binstall", "-V"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }

    String::from_utf8(output.stdout).ok()
}

pub fn install_crate_curl(details: &CrateDetails, fallback: bool) -> Result<(), InstallError> {
    match download_tarball(&details.crate_name, &details.version, &details.target) {
        Ok(mut child) => {
            let tar_output = untar(child.stdout().take().unwrap())?;
            child.wait_with_output_checked_status()?;
            // tar output contains its own newline.
            print!(
                "Installed {} {} to ~/.cargo/bin:\n{}",
                details.crate_name, details.version, tar_output
            );
            Ok(())
        }
        Err(err) if err.is_curl_404() => {
            if !fallback {
                return Err(InstallError::NoFallback(details.clone()));
            }

            println!(
                "Could not find a pre-built package for {} {} on {}.",
                details.crate_name, details.version, details.target
            );
            println!("We have reported your installation request, so it should be built soon.");

            println!("Falling back to `cargo install`.");

            let status = prepare_cargo_install_cmd(details).status()?;

            if status.success() {
                Ok(())
            } else {
                Err(InstallError::CargoInstallFailed)
            }
        }
        Err(err) => Err(err),
    }
}

pub fn get_latest_version(crate_name: &str) -> Result<String, InstallError> {
    let url = format!("https://crates.io/api/v1/crates/{}", crate_name);

    curl_json(&url)
        .map_err(|e| {
            if e.is_curl_404() {
                InstallError::CrateDoesNotExist {
                    crate_name: crate_name.to_string(),
                }
            } else {
                e
            }
        })?
        .get_owned(&"versions")
        .and_then(|value| value.get_owned(&0))
        .and_then(|value| value.get_owned(&"num"))
        .and_then(JsonValueExt::try_into_string)
        .map_err(InstallError::from)
}

pub fn get_target_triple() -> Result<String, InstallError> {
    // Credit to https://stackoverflow.com/a/63866386
    let output = std::process::Command::new("rustc")
        .arg("--version")
        .arg("--verbose")
        .output()?;
    let stdout = utf8_to_string_lossy(output.stdout);
    for line in stdout.lines() {
        if let Some(target) = line.strip_prefix("host: ") {
            return Ok(target.to_string());
        }
    }
    Err(CommandFailed {
        command: "rustc --version --verbose".to_string(),
        stdout,
        stderr: utf8_to_string_lossy(output.stderr),
    }
    .into())
}

pub fn report_stats_in_background(details: &CrateDetails) {
    let stats_url = format!(
        "https://warehouse-clerk-tmp.vercel.app/api/crate/{}-{}-{}.tar.gz",
        details.crate_name, details.version, details.target
    );

    // Simply spawn the curl command to report stat.
    //
    // It's ok for it to fail and we would let the init process reap
    // the `curl` process.
    prepare_curl_head_cmd(&stats_url).spawn().ok();
}

pub fn do_dry_run_curl(crate_details: &CrateDetails) -> String {
    let crate_download_url = format!(
        "https://github.com/cargo-bins/cargo-quickinstall/releases/download/\
                 {crate_name}-{version}-{target}/{crate_name}-{version}-{target}.tar.gz",
        crate_name = crate_details.crate_name,
        version = crate_details.version,
        target = crate_details.target
    );
    if curl_head(&crate_download_url).is_ok() {
        let cargo_bin_dir = home::cargo_home().unwrap().join("bin");
        let cargo_bin_dir_str = cargo_bin_dir.to_str().unwrap();
        format!(
            "{curl_cmd:?} | {untar_cmd:?}",
            curl_cmd = prepare_curl_bytes_cmd(&crate_download_url),
            untar_cmd = prepare_untar_cmd(cargo_bin_dir_str)
        )
    } else {
        let cargo_install_cmd = prepare_cargo_install_cmd(crate_details);
        format!("{:?}", cargo_install_cmd)
    }
}

fn untar(input: process::ChildStdout) -> Result<String, InstallError> {
    let mut bin_dir = home::cargo_home().unwrap();
    bin_dir.push("bin");

    let output = std::process::Command::new("tar")
        .arg("-xzvvf")
        .arg("-")
        .arg("-C")
        .arg(bin_dir)
        .stdin(input)
        .output_checked_status()?;

    let stdout = utf8_to_string_lossy(output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);

    let mut s = stdout;
    s += &stderr;

    Ok(s)
}

fn prepare_curl_head_cmd(url: &str) -> std::process::Command {
    let mut cmd = std::process::Command::new("curl");

    cmd.arg("--user-agent")
        .arg("cargo-quickinstall client (alsuren@gmail.com)")
        .arg("--head")
        .arg("--silent")
        .arg("--show-error")
        .arg("--fail")
        .arg("--location")
        .arg(url);

    cmd
}

fn curl_head(url: &str) -> Result<Vec<u8>, InstallError> {
    prepare_curl_head_cmd(url)
        .output_checked_status()
        .map(|output| output.stdout)
}

fn curl(url: &str) -> Result<ChildWithCmd, InstallError> {
    let mut cmd = prepare_curl_bytes_cmd(url);
    cmd.stdin(process::Stdio::null())
        .stdout(process::Stdio::piped())
        .stderr(process::Stdio::piped());
    cmd.spawn_with_cmd()
}

fn curl_bytes(url: &str) -> Result<Vec<u8>, InstallError> {
    prepare_curl_bytes_cmd(url)
        .output_checked_status()
        .map(|output| output.stdout)
}

fn curl_string(url: &str) -> Result<String, InstallError> {
    curl_bytes(url).map(utf8_to_string_lossy)
}

pub fn curl_json(url: &str) -> Result<JsonValue, InstallError> {
    curl_string(url)?
        .parse()
        .map_err(|err| InstallError::InvalidJson {
            url: url.to_string(),
            err,
        })
}

fn download_tarball(
    crate_name: &str,
    version: &str,
    target: &str,
) -> Result<ChildWithCmd, InstallError> {
    let github_url = format!(
        "https://github.com/cargo-bins/cargo-quickinstall/releases/download/{crate_name}-{version}-{target}/{crate_name}-{version}-{target}.tar.gz",
        crate_name=crate_name, version=version, target=target,
    );
    curl(&github_url)
}

fn prepare_curl_bytes_cmd(url: &str) -> std::process::Command {
    let mut cmd = std::process::Command::new("curl");
    cmd.arg("--user-agent")
        .arg("cargo-quickinstall client (alsuren@gmail.com)")
        .arg("--location")
        .arg("--silent")
        .arg("--show-error")
        .arg("--fail")
        .arg(url);
    cmd
}

fn prepare_untar_cmd(cargo_bin_dir: &str) -> std::process::Command {
    let mut cmd = std::process::Command::new("tar");
    cmd.arg("-xzvvf").arg("-").arg("-C").arg(cargo_bin_dir);
    cmd
}

fn prepare_cargo_install_cmd(details: &CrateDetails) -> std::process::Command {
    let mut cmd = std::process::Command::new("cargo");
    cmd.arg("install")
        .arg(&details.crate_name)
        .arg("--version")
        .arg(&details.version);
    cmd
}
