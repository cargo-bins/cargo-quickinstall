//! Pre-built binary crate installer.
//!
//! Tries to install pre-built binary crates whenever possibles.  Falls back to
//! `cargo install` otherwise.

use std::convert::TryInto;
use std::io::ErrorKind;
use tinyjson::JsonValue;

pub mod install_error;

use install_error::*;

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
        Ok(tarball) => {
            let tar_output = untar(tarball)?;
            // tar output contains its own newline.
            print!(
                "Installed {} {} to ~/.cargo/bin:\n{}",
                details.crate_name, details.version, tar_output
            );
            Ok(())
        }
        Err(err) if err.is_curl_404() => {
            println!(
                "Could not find a pre-built package for {} {} on {}.",
                details.crate_name, details.version, details.target
            );
            println!("We have reported your installation request, so it should be built soon.");

            report_stats_in_background(details);

            if !fallback {
                return Err(InstallError::NoFallback(details.clone()));
            }

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

    let parsed = curl_json(&url).map_err(|e| {
        if e.is_curl_404() {
            InstallError::CrateDoesNotExist {
                crate_name: crate_name.to_string(),
            }
        } else {
            e
        }
    })?;
    Ok(parsed["versions"][0]["num"].clone().try_into().unwrap())
}

pub fn get_target_triple() -> Result<String, InstallError> {
    // Credit to https://stackoverflow.com/a/63866386
    let output = std::process::Command::new("rustc")
        .arg("--version")
        .arg("--verbose")
        .output()?;
    for line in String::from_utf8(output.stdout).unwrap().lines() {
        if let Some(target) = line.strip_prefix("host: ") {
            return Ok(target.to_string());
        }
    }
    Err(CommandFailed {
        command: "rustc --version --verbose".to_string(),
        stdout: "".to_string(),
        stderr: String::from_utf8(output.stderr).unwrap(),
    }
    .into())
}

pub fn report_stats_in_background(details: &CrateDetails) -> std::thread::JoinHandle<()> {
    let tarball_name = format!(
        "{}-{}-{}.tar.gz",
        details.crate_name, details.version, details.target
    );

    let stats_url = format!(
        "https://warehouse-clerk-tmp.vercel.app/api/crate/{}",
        tarball_name
    );
    std::thread::spawn(move || {
        // warehouse-clerk is known to return 404. This is fine. We only use it for stats gathering.
        curl_head(&stats_url).unwrap_or_default();
    })
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

fn untar(tarball: Vec<u8>) -> Result<String, InstallError> {
    use std::io::Write;

    if tarball.is_empty() {
        panic!("We fetched a tarball, but it was empty. Please report this as a bug.");
    }
    let cargo_home = home::cargo_home().unwrap();
    let bin_dir = cargo_home.join("bin");
    let mut tar_command = std::process::Command::new("tar");
    tar_command
        .arg("-xzvvf")
        .arg("-")
        .arg("-C")
        .arg(bin_dir)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    let mut process = tar_command.spawn()?;

    process.stdin.take().unwrap().write_all(&tarball).unwrap();

    let output = process.wait_with_output()?;

    let stdout = String::from_utf8(output.stdout).unwrap();
    let stderr = String::from_utf8(output.stderr).unwrap();

    if !output.status.success() {
        return Err(CommandFailed {
            command: "tar -xzvvf - -C ~/.cargo/bin".to_string(),
            stdout,
            stderr,
        }
        .into());
    }

    Ok(stdout + &stderr)
}

fn curl_head(url: &str) -> Result<Vec<u8>, InstallError> {
    let output = std::process::Command::new("curl")
        .arg("--user-agent")
        .arg("cargo-quickinstall client (alsuren@gmail.com)")
        .arg("--head")
        .arg("--silent")
        .arg("--show-error")
        .arg("--fail")
        .arg("--location")
        .arg(url)
        .output()?;
    if !output.status.success() {
        let stdout = String::from_utf8(output.stdout).unwrap();
        let stderr = String::from_utf8(output.stderr).unwrap();
        return Err(CommandFailed {
            command: format!("curl --head --fail '{}'", url),
            stdout,
            stderr,
        }
        .into());
    }
    Ok(output.stdout)
}

fn curl_bytes(url: &str) -> Result<Vec<u8>, InstallError> {
    let output = prepare_curl_bytes_cmd(url).output()?;
    if !output.status.success() {
        let stdout = String::from_utf8(output.stdout).unwrap();
        let stderr = String::from_utf8(output.stderr).unwrap();
        return Err(CommandFailed {
            command: format!("curl --location --fail '{}'", url),
            stdout,
            stderr,
        }
        .into());
    }
    Ok(output.stdout)
}

fn curl_string(url: &str) -> Result<String, InstallError> {
    let stdout = curl_bytes(url)?;
    let parsed = String::from_utf8(stdout).unwrap();
    Ok(parsed)
}

pub fn curl_json(url: &str) -> Result<JsonValue, InstallError> {
    let stdout = curl_string(url)?;
    let parsed = stdout
        .parse()
        .map_err(|_| std::io::Error::new(ErrorKind::InvalidData, "Unable to parse JSON."))?;
    Ok(parsed)
}

fn download_tarball(
    crate_name: &str,
    version: &str,
    target: &str,
) -> Result<Vec<u8>, InstallError> {
    let github_url = format!(
        "https://github.com/cargo-bins/cargo-quickinstall/releases/download/{crate_name}-{version}-{target}/{crate_name}-{version}-{target}.tar.gz",
        crate_name=crate_name, version=version, target=target,
    );
    curl_bytes(&github_url)
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
