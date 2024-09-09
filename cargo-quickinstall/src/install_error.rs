use crate::{CommandFailed, CrateDetails, JsonExtError};
use std::fmt::{Debug, Display};

use tinyjson::JsonParseError;

pub enum InstallError {
    MissingCrateNameArgument(&'static str),
    CommandFailed(CommandFailed),
    IoError(std::io::Error),
    CargoInstallFailed,
    CrateDoesNotExist { crate_name: String },
    NoFallback(CrateDetails),
    InvalidJson { url: String, err: JsonParseError },
    JsonErr(JsonExtError),
    FailToParseRustcOutput { reason: &'static str },
}

impl InstallError {
    pub fn is_curl_404(&self) -> bool {
        matches!(
            self,
            Self::CommandFailed(CommandFailed { stderr, .. })
            if stderr.contains("curl: (22) The requested URL returned error: 404")
        )
    }
}

impl std::error::Error for InstallError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::IoError(io_err) => Some(io_err),
            Self::InvalidJson { err, .. } => Some(err),
            Self::JsonErr(err) => Some(err),
            _ => None,
        }
    }
}

// We implement `Debug` in terms of `Display`, because "Error: {:?}"
// is what is shown to the user if you return an error from `main()`.
impl Debug for InstallError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write! {f, "{}", self}
    }
}

impl Display for InstallError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            &InstallError::MissingCrateNameArgument(usage_text) => {
                write!(f, "No crate name specified.\n\n{}", usage_text)
            }
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
            InstallError::CargoInstallFailed => {
                f.write_str("`cargo install` didn't work either. Looks like you're on your own.")
            }

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
            InstallError::InvalidJson { url, err } => {
                write!(f, "Failed to parse json downloaded from '{url}': {err}",)
            }
            InstallError::JsonErr(err) => write!(f, "{err}"),
            InstallError::FailToParseRustcOutput { reason } => {
                write!(f, "Failed to parse `rustc -vV` output: {reason}")
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

impl From<JsonExtError> for InstallError {
    fn from(err: JsonExtError) -> InstallError {
        InstallError::JsonErr(err)
    }
}

#[derive(Debug)]
pub enum InstallSuccess {
    InstalledFromTarball,
    BuiltFromSource,
}

/**
 * Returns a status string for reporting to our stats server.
 *
 * The return type is a static string to encourage us to keep the cardinality vaguely small-ish,
 * and avoid us accidentally dumping personally identifiable information into influxdb.
 *
 * If we find ourselves getting a lot of a particular genre of error, we can always make a new
 * release to split things out a bit more.
 *
 * There is no requirement for cargo-quickinstall and cargo-binstall to agree on the status strings,
 * but it is probably a good idea to keep at least the first two in sync.
 */
pub fn install_result_to_status_str(result: &Result<InstallSuccess, InstallError>) -> &'static str {
    match result {
        Ok(InstallSuccess::InstalledFromTarball) => "installed-from-tarball",
        Ok(InstallSuccess::BuiltFromSource) => "built-from-source",
        Err(InstallError::MissingCrateNameArgument(_)) => "missing-crate-name-argument",
        Err(InstallError::CommandFailed(_)) => "command-failed",
        Err(InstallError::IoError(_)) => "io-error",
        Err(InstallError::CargoInstallFailed) => "cargo-install-failed",
        Err(InstallError::CrateDoesNotExist { .. }) => "crate-does-not-exist",
        Err(InstallError::NoFallback(_)) => "no-fallback",
        Err(InstallError::InvalidJson { .. }) => "invalid-json",
        Err(InstallError::JsonErr(_)) => "json-err",
        Err(InstallError::FailToParseRustcOutput { .. }) => "fail-to-parse-rustc-output",
    }
}
