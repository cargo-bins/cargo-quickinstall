//! Pre-built binary crate installer.
//!
//! Tries to install pre-built binary crates whenever possibles.  Falls back to
//! `cargo install` otherwise.

use guess_host_triple::guess_host_triple;
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

    curl_head(&url)?;

    let cargo_bin_dir = get_cargo_bin_dir()?;

    if archive_format == "tgz" {
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

pub fn install_crate_curl(
    details: &CrateDetails,
    fallback: bool,
) -> Result<InstallSuccess, InstallError> {
    let urls = get_quickinstall_download_urls(details);

    let res = match curl_and_untar(&urls[0]) {
        Err(err) if err.is_curl_404() => {
            println!("Fallback to old release schema");

            curl_and_untar(&urls[1])
        }
        res => res,
    };

    match res {
        Ok(tar_output) => {
            let bin_dir = get_cargo_bin_dir()?;

            // tar output contains its own newline.
            print!(
                "Installed {crate_name}@{version} to {bin_dir}:\n{tar_output}",
                crate_name = details.crate_name,
                version = details.version,
                bin_dir = bin_dir.display(),
            );
            Ok(InstallSuccess::InstalledFromTarball)
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
                Ok(InstallSuccess::BuiltFromSource)
            } else {
                Err(InstallError::CargoInstallFailed)
            }
        }
        Err(err) => Err(err),
    }
}

fn curl_and_untar(url: &str) -> Result<String, InstallError> {
    untar(curl(url)?)
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
        .get_owned(&"crate")?
        .get_owned(&"max_stable_version")?
        .try_into_string()
        .map_err(From::from)
}

pub fn get_target_triple() -> Result<String, InstallError> {
    match get_target_triple_from_rustc() {
        Ok(target) => Ok(target),
        Err(err) => {
            if let Some(target) = guess_host_triple() {
                println!("get_target_triple_from_rustc() failed due to {err}, fallback to guess_host_triple");
                Ok(target.to_string())
            } else {
                println!("get_target_triple_from_rustc() failed due to {err}, fallback to guess_host_triple also failed");
                Err(err)
            }
        }
    }
}

fn get_target_triple_from_rustc() -> Result<String, InstallError> {
    // Credit to https://stackoverflow.com/a/63866386
    let output = std::process::Command::new("rustc")
        .arg("--version")
        .arg("--verbose")
        .output_checked_status()?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let target = stdout
        .lines()
        .find_map(|line| line.strip_prefix("host: "))
        .ok_or(InstallError::FailToParseRustcOutput {
            reason: "Fail to find any line starts with 'host: '.",
        })?;

    // The target triplets have the form of 'arch-vendor-system'.
    //
    // When building for Linux (e.g. the 'system' part is
    // 'linux-something'), replace the vendor with 'unknown'
    // so that mapping to rust standard targets happens correctly.
    //
    // For example, alpine set `rustc` host triple to
    // `x86_64-alpine-linux-musl`.
    //
    // Here we use splitn with n=4 since we just need to check
    // the third part to see if it equals to "linux" and verify
    // that we have at least three parts.
    let mut parts: Vec<&str> = target.splitn(4, '-').collect();
    let os = *parts.get(2).ok_or(InstallError::FailToParseRustcOutput {
        reason: "rustc returned an invalid triple, contains less than three parts",
    })?;
    if os == "linux" {
        parts[1] = "unknown";
    }
    Ok(parts.join("-"))
}

pub fn report_stats_in_background(
    details: &CrateDetails,
    result: &Result<InstallSuccess, InstallError>,
) {
    let stats_url = format!(
        "https://cargo-quickinstall-stats-server.fly.dev/record-install?crate={crate}&version={version}&target={target}&agent={agent}&status={status}",
        crate = url_encode(&details.crate_name),
        version = url_encode(&details.version),
        target = url_encode(&details.target),
        agent = url_encode(concat!("cargo-quickinstall/", env!("CARGO_PKG_VERSION"))),
        status = install_result_to_status_str(result),
    );

    // Simply spawn the curl command to report stat.
    //
    // It's ok for it to fail and we would let the init process reap
    // the `curl` process.
    prepare_curl_post_cmd(&stats_url)
        .stdin(process::Stdio::null())
        .stdout(process::Stdio::null())
        .stderr(process::Stdio::null())
        .spawn()
        .ok();
}

fn url_encode(input: &str) -> String {
    let mut encoded = String::with_capacity(input.len());

    for c in input.chars() {
        match c {
            'A'..='Z' | 'a'..='z' | '0'..='9' | '-' | '_' | '.' | '~' => encoded.push(c),
            _ => encoded.push_str(&format!("%{:02X}", c as u8)),
        }
    }

    encoded
}

fn format_curl_and_untar_cmd(url: &str, bin_dir: &Path) -> String {
    format!(
        "{curl_cmd} | {untar_cmd}",
        curl_cmd = prepare_curl_bytes_cmd(url).formattable(),
        untar_cmd = prepare_untar_cmd(bin_dir).formattable(),
    )
}

pub fn do_dry_run_curl(
    crate_details: &CrateDetails,
    fallback: bool,
) -> Result<String, InstallError> {
    let urls = get_quickinstall_download_urls(crate_details);

    let (url, res) = match curl_head(&urls[0]) {
        Err(err) if err.is_curl_404() => (&urls[1], curl_head(&urls[1])),
        res => (&urls[0], res),
    };

    match res {
        Ok(_) => {
            let cargo_bin_dir = get_cargo_bin_dir()?;

            Ok(format_curl_and_untar_cmd(url, &cargo_bin_dir))
        }
        Err(err) if err.is_curl_404() && fallback => {
            let cargo_install_cmd = prepare_cargo_install_cmd(crate_details);
            Ok(format!("{}", cargo_install_cmd.formattable()))
        }
        Err(err) => Err(err),
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

fn prepare_curl_post_cmd(url: &str) -> std::process::Command {
    let mut cmd = prepare_curl_cmd();
    cmd.args(["-X", "POST"]).arg(url);
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

fn get_quickinstall_download_urls(
    CrateDetails {
        crate_name,
        version,
        target,
    }: &CrateDetails,
) -> [String; 2] {
    [format!(
        "https://github.com/cargo-bins/cargo-quickinstall/releases/download/{crate_name}-{version}/{crate_name}-{version}-{target}.tar.gz",
    ),
    format!(
        "https://github.com/cargo-bins/cargo-quickinstall/releases/download/{crate_name}-{version}-{target}/{crate_name}-{version}-{target}.tar.gz",
    )]
}

fn prepare_curl_cmd() -> std::process::Command {
    let mut cmd = std::process::Command::new("curl");
    cmd.args([
        "--user-agent",
        concat!(
            "cargo-quickinstall/",
            env!("CARGO_PKG_VERSION"),
            " client (alsuren@gmail.com)",
        ),
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
