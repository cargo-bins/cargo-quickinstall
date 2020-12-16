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

#[derive(Debug)]
struct CommandFailed {
    command: String,
    stdout: String,
    stderr: String,
}
impl CommandFailed {
    fn is_curl_404(&self) -> bool {
        self.stderr
            .contains("curl: (22) The requested URL returned error: 404")
    }
}

enum InstallError {
    CommandFailed(CommandFailed),
    IoError(std::io::Error),
    CargoInstallFailed,
    CrateDoesNotExist { crate_name: String },
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

fn bash_stdout(command: &str) -> Result<String, InstallError> {
    let command_string = format!("set -euo pipefail && {}", command);
    let output = std::process::Command::new("bash")
        .arg("-c")
        .arg(&command_string)
        .output()?;

    let mut stdout = String::from_utf8(output.stdout).unwrap();
    let len = stdout.trim_end_matches('\n').len();
    stdout.truncate(len);

    if !output.status.success() {
        let stderr = String::from_utf8(output.stderr).unwrap();
        return Err(CommandFailed {
            command: command.to_string(),
            stdout,
            stderr,
        }
        .into());
    }

    Ok(stdout)
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
        .output()
        .map_err(|e| dbg!(e))?;
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

    let parsed = dbg!(curl_json(&url)).map_err(|e| match e {
        InstallError::CommandFailed(err) if err.is_curl_404() => InstallError::CrateDoesNotExist {
            crate_name: crate_name.to_string(),
        },
        _ => e,
    })?;
    Ok(parsed["versions"][0]["num"].clone().try_into().unwrap())
}

fn get_target_triple() -> Result<String, InstallError> {
    // Credit to https://stackoverflow.com/a/63866386
    bash_stdout("rustc --version --verbose | sed -n 's/host: //p'")
}

fn report_stats_in_background(
    crate_name: &str,
    version: &str,
    target: &str,
) -> std::thread::JoinHandle<()> {
    let tarball_name = format!("{}-{}-{}.tar.gz", crate_name, version, target);

    // warehouse-clerk is known to return 404. This is fine. We only use it for stats gathering.
    let stats_url = format!(
        "https://warehouse-clerk-tmp.vercel.app/api/crate/{}",
        tarball_name
    );
    std::thread::spawn(move || {
        bash_stdout(&format!("curl --head '{}'", stats_url)).unwrap();
    })
}

fn install_crate(crate_name: &str, version: &str, target: &str) -> Result<(), InstallError> {
    let tarball_name = format!("{}-{}-{}.tar.gz", crate_name, version, target);

    let download_url = format!(
        "https://dl.bintray.com/cargo-quickinstall/cargo-quickinstall/{}",
        tarball_name
    );
    let install_command = format!(
        "curl --silent --show-error --location --fail '{}' | tar -xzvvf - -C ~/.cargo/bin 2>&1",
        download_url
    );
    match bash_stdout(&install_command) {
        Ok(tar_output) => {
            println!(
                "Installed {} {} to ~/.cargo/bin:\n{}",
                crate_name, version, tar_output
            );
            Ok(())
        }
        Err(InstallError::CommandFailed(err)) if err.is_curl_404() => {
            println!(
                "Could not find a pre-built package for {} {} on {}.",
                crate_name, version, target
            );
            println!("We have reported your installation request, so it should be built soon.");
            println!("Falling back to `cargo install`.");

            let status = std::process::Command::new("cargo")
                .arg("install")
                .arg(crate_name)
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
    let args = std::env::args().collect::<Vec<_>>();
    let crate_name = if let Some(true) = args.get(1).map(|a| a == "quickinstall") {
        args.get(2)
    } else {
        args.get(1)
    };

    let crate_name = crate_name.ok_or("USAGE: cargo quickinstall CRATE_NAME")?;
    let version = get_latest_version(crate_name)?;
    let target = get_target_triple()?;

    let stats_handle = report_stats_in_background(crate_name, &version, &target);
    install_crate(crate_name, &version, &target)?;
    stats_handle.join().unwrap();

    Ok(())
}
