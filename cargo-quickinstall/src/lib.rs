//! Pre-built binary crate installer.
//!
//! Tries to install pre-built binary crates whenever possibles.  Falls back to
//! `cargo install` otherwise.

use std::{fs::File, path::Path, process};
use tempfile::NamedTempFile;
use tinyjson::JsonValue;

pub mod install_error;

use install_error::*;

mod command_ext;
pub use command_ext::{ChildWithCommand, CommandExt, CommandFormattable};

mod json_value_ext;
pub use json_value_ext::{JsonExtError, JsonKey, JsonValueExt};

mod utils;
pub use utils::{get_cargo_bin_dir, utf8_to_string_lossy};

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

/// Return (archive_format, url)
fn get_binstall_upstream_url(target: &str) -> (&'static str, String) {
    let archive_format = if target.contains("linux") {
        "tgz"
    } else {
        "zip"
    };
    let url = format!("https://github.com/cargo-bins/cargo-binstall/releases/latest/download/cargo-binstall-{target}.{archive_format}");

    (archive_format, url)
}

/// Attempt to download and install cargo-binstall from upstream.
pub fn download_and_install_binstall_from_upstream(target: &str) -> Result<(), InstallError> {
    let (archive_format, url) = get_binstall_upstream_url(target);

    if archive_format == "tgz" {
        untar(curl(&url)?)?;

        Ok(())
    } else {
        assert_eq!(archive_format, "zip");

        let (zip_file, zip_file_temp_path) = NamedTempFile::new()?.into_parts();

        curl_file(&url, zip_file)?;

        unzip(&zip_file_temp_path)?;

        Ok(())
    }
}

pub fn do_dry_run_download_and_install_binstall_from_upstream(
    target: &str,
) -> Result<String, InstallError> {
    let (archive_format, url) = get_binstall_upstream_url(target);

    let cargo_bin_dir = get_cargo_bin_dir()?;

    if archive_format == ".tgz" {
        Ok(format_curl_and_untar_cmd(&url, &cargo_bin_dir))
    } else {
        Ok(format!(
            "temp=\"$(mktemp)\"\n{curl_cmd} >\"$temp\"\nunzip \"$temp\" -d {extdir}",
            curl_cmd = prepare_curl_bytes_cmd(&url).formattable(),
            extdir = cargo_bin_dir.display(),
        ))
    }
}

pub fn unzip(zip_file: &Path) -> Result<(), InstallError> {
    let bin_dir = get_cargo_bin_dir()?;

    process::Command::new("unzip")
        .arg(zip_file)
        .arg("-d")
        .arg(bin_dir)
        .output_checked_status()?;

    Ok(())
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
    // download_tarball will not include any 404 error from curl, but only
    // error when spawning curl.
    //
    // untar will wait on curl, so it will include the 404 error.
    match untar(download_tarball(
        &details.crate_name,
        &details.version,
        &details.target,
    )?) {
        Ok(tar_output) => {
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
        .get_owned(&"versions")?
        .get_owned(&0)?
        .get_owned(&"num")?
        .try_into_string()
        .map_err(From::from)
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

fn format_curl_and_untar_cmd(url: &str, bin_dir: &Path) -> String {
    format!(
        "{curl_cmd} | {untar_cmd}",
        curl_cmd = prepare_curl_bytes_cmd(url).formattable(),
        untar_cmd = prepare_untar_cmd(bin_dir).formattable(),
    )
}

pub fn do_dry_run_curl(crate_details: &CrateDetails) -> Result<String, InstallError> {
    let crate_download_url = format!(
        "https://github.com/cargo-bins/cargo-quickinstall/releases/download/\
                 {crate_name}-{version}-{target}/{crate_name}-{version}-{target}.tar.gz",
        crate_name = crate_details.crate_name,
        version = crate_details.version,
        target = crate_details.target
    );
    if curl_head(&crate_download_url).is_ok() {
        let cargo_bin_dir = get_cargo_bin_dir()?;

        Ok(format_curl_and_untar_cmd(
            &crate_download_url,
            &cargo_bin_dir,
        ))
    } else {
        let cargo_install_cmd = prepare_cargo_install_cmd(crate_details);
        Ok(format!("{}", cargo_install_cmd.formattable()))
    }
}

fn untar(mut curl: ChildWithCommand) -> Result<String, InstallError> {
    let bin_dir = get_cargo_bin_dir()?;

    let res = prepare_untar_cmd(&bin_dir)
        .stdin(curl.stdout().take().unwrap())
        .output_checked_status();

    // Propagate this error before Propagating error tar since
    // if tar fails, it's likely due to curl failed.
    //
    // For example, this would enable the 404 error to be propagated
    // correctly.
    curl.wait_with_output_checked_status()?;

    let output = res?;

    let stdout = utf8_to_string_lossy(output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);

    let mut s = stdout;
    s += &stderr;

    Ok(s)
}

fn prepare_curl_head_cmd(url: &str) -> std::process::Command {
    let mut cmd = prepare_curl_cmd();
    cmd.arg("--head").arg(url);
    cmd
}

fn curl_head(url: &str) -> Result<Vec<u8>, InstallError> {
    prepare_curl_head_cmd(url)
        .output_checked_status()
        .map(|output| output.stdout)
}

fn curl(url: &str) -> Result<ChildWithCommand, InstallError> {
    let mut cmd = prepare_curl_bytes_cmd(url);
    cmd.stdin(process::Stdio::null())
        .stdout(process::Stdio::piped())
        .stderr(process::Stdio::piped());
    cmd.spawn_with_cmd()
}

fn curl_file(url: &str, file: File) -> Result<(), InstallError> {
    prepare_curl_bytes_cmd(url)
        .stdin(process::Stdio::null())
        .stdout(file)
        .stderr(process::Stdio::piped())
        .output_checked_status()?;

    Ok(())
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
) -> Result<ChildWithCommand, InstallError> {
    let github_url = format!(
        "https://github.com/cargo-bins/cargo-quickinstall/releases/download/{crate_name}-{version}-{target}/{crate_name}-{version}-{target}.tar.gz",
        crate_name=crate_name, version=version, target=target,
    );
    curl(&github_url)
}

fn prepare_curl_cmd() -> std::process::Command {
    let mut cmd = std::process::Command::new("curl");
    cmd.args([
        "--user-agent",
        "cargo-quickinstall client (alsuren@gmail.com)",
        "--location",
        "--silent",
        "--show-error",
        "--fail",
    ]);
    cmd
}

fn prepare_curl_bytes_cmd(url: &str) -> std::process::Command {
    let mut cmd = prepare_curl_cmd();
    cmd.arg(url);
    cmd
}

fn prepare_untar_cmd(cargo_bin_dir: &Path) -> std::process::Command {
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
