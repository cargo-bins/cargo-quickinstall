// cargo-quickinstall is optimised so that bootstrapping with
//
//     cargo install cargo-quickinstall
//
// is quick. It's basically a glorified bash script.
//
// I suspect that there will be ways to clean this up without increasing
// the bootstrapping time too much. Patches to do this would be very welcome.

use std::convert::TryInto;
use std::io::ErrorKind;
use tinyjson::JsonValue;

mod args;

#[derive(Debug)]
struct CommandFailed {
    command: String,
    stdout: String,
    stderr: String,
}

#[derive(Clone)]
struct CrateDetails {
    crate_name: String,
    version: String,
    target: String,
}

enum InstallError {
    CommandFailed(CommandFailed),
    IoError(std::io::Error),
    CargoInstallFailed,
    CrateDoesNotExist { crate_name: String },
    NoFallback(CrateDetails),
}

impl InstallError {
    fn is_curl_404(&self) -> bool {
        match self {
            Self::CommandFailed(CommandFailed { stderr, .. })
                if stderr.contains("curl: (22) The requested URL returned error: 404") =>
            {
                true
            }
            _ => false,
        }
    }
}

impl std::error::Error for InstallError {}

// We implement `Debug` in terms of `Display`, because "Error: {:?}"
// is what is shown to the user if you return an error from `main()`.
impl std::fmt::Debug for InstallError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write! {f, "{}", self}
    }
}

impl std::fmt::Display for InstallError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            InstallError::CommandFailed(CommandFailed {
                command,
                stdout,
                stderr,
            }) => {
                write!(f, "Command failed:\n    {}\n", command)?;
                if !stdout.is_empty() {
                    write!(f, "Stdout:\n{}\n", stdout)?;
                }
                if !stderr.is_empty() {
                    write!(f, "Stderr:\n{}", stderr)?;
                }

                Ok(())
            }
            InstallError::IoError(e) => write!(f, "{}", e),
            InstallError::CargoInstallFailed => write!(
                f,
                "`cargo install` didn't work either. Looks like you're on your own."
            ),
            InstallError::CrateDoesNotExist { crate_name } => {
                write!(f, "`{}` does not exist on crates.io.", crate_name)
            }
            InstallError::NoFallback(crate_details) => {
                write!(
                    f,
                    "Could not find a pre-built package for {} {} on {}.",
                    crate_details.crate_name, crate_details.version, crate_details.target
                )
            }
        }
    }
}

impl From<std::io::Error> for InstallError {
    fn from(err: std::io::Error) -> InstallError {
        InstallError::IoError(err)
    }
}
impl From<CommandFailed> for InstallError {
    fn from(err: CommandFailed) -> InstallError {
        InstallError::CommandFailed(err)
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
    let output = std::process::Command::new("curl")
        .arg("--user-agent")
        .arg("cargo-quickinstall client (alsuren@gmail.com)")
        .arg("--location")
        .arg("--silent")
        .arg("--show-error")
        .arg("--fail")
        .arg(url)
        .output()?;
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

fn curl_json(url: &str) -> Result<JsonValue, InstallError> {
    let stdout = curl_string(url)?;
    let parsed = stdout
        .parse()
        .map_err(|_| std::io::Error::new(ErrorKind::InvalidData, "Unable to parse JSON."))?;
    Ok(parsed)
}

fn get_latest_version(crate_name: &str) -> Result<String, InstallError> {
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

fn get_target_triple() -> Result<String, InstallError> {
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

fn report_stats_in_background(details: &CrateDetails) -> std::thread::JoinHandle<()> {
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

fn download_tarball(
    crate_name: &str,
    version: &str,
    target: &str,
) -> Result<Vec<u8>, InstallError> {
    let github_url = format!(
        "https://github.com/alsuren/cargo-quickinstall/releases/download/{crate_name}-{version}-{target}/{crate_name}-{version}-{target}.tar.gz",
        crate_name=crate_name, version=version, target=target,
    );
    curl_bytes(&github_url)
}

fn install_crate(details: &CrateDetails, fallback: bool) -> Result<(), InstallError> {
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
            if !fallback {
                return Err(InstallError::NoFallback(details.clone()));
            }

            println!(
                "Could not find a pre-built package for {} {} on {}.",
                details.crate_name, details.version, details.target
            );
            println!("We have reported your installation request, so it should be built soon.");
            println!("Falling back to `cargo install`.");

            let status = std::process::Command::new("cargo")
                .arg("install")
                .arg(&details.crate_name)
                .arg("--version")
                .arg(&details.version)
                .status()?;

            if status.success() {
                Ok(())
            } else {
                Err(InstallError::CargoInstallFailed)
            }
        }
        Err(err) => Err(err),
    }
}

fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync + 'static>> {
    let options = args::options_from_env()?;

    let crate_name = options.crate_name.ok_or(args::USAGE)?;
    let version = match options.version {
        Some(version) => version,
        None => get_latest_version(&crate_name)?,
    };
    let target = match options.target {
        Some(target) => target,
        None => get_target_triple()?,
    };

    let details = CrateDetails {
        crate_name,
        version,
        target,
    };

    //let stats_handle = report_stats_in_background(&crate_name, &version, &target);
    let stats_handle = report_stats_in_background(&details);
    install_crate(&details, options.fallback)?;
    stats_handle.join().unwrap();

    Ok(())
}
