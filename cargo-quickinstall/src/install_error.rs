use crate::{CommandFailed, CrateDetails};
use std::fmt::{Debug, Display};

pub enum InstallError {
    MissingCrateNameArgument(&'static str),
    CommandFailed(CommandFailed),
    IoError(std::io::Error),
    CargoInstallFailed,
    CrateDoesNotExist { crate_name: String },
    NoFallback(CrateDetails),
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
        if let Self::IoError(io_err) = self {
            Some(io_err)
        } else {
            None
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
