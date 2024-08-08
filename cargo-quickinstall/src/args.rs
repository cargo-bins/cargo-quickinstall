use std::cmp::Ordering;

pub const USAGE: &str = "USAGE:
    cargo quickinstall [OPTIONS] -- <CRATES> ...

For more information try --help
";
pub const HELP: &str = "USAGE:
    cargo quickinstall [OPTIONS] -- <CRATES> ...

<CRATES> ... - can be one or more crates. Each one can be either simply a name, or a name and
               version `cargo-quickinstall@0.2.7`.

OPTIONS:
        --version <VERSION>         Specify a version to install. It's invalid specify this in
                                    batch installtion mode.

                                    NOTE that if you specify --version when only providing one crate
                                    to install, then --version takes precedence over the version
                                    specified in the <CRATES>.

        --target <TRIPLE>           Install package for the target triple
        --force                     Install the <CRATES> even if they are already installed.
                                    Only effective when using `cargo-binstall`.
        --try-upstream              Try looking for official builds from the upstream maintainers.
                                    This takes a few extra seconds.
        --no-fallback               Don't fall back to `cargo install`
        --no-binstall               Don't use `cargo binstall` to install packages. `cargo-binstall`
                                    sets metadata required for `cargo uninstall`, so only use
                                    `--no-binstall` if you know you don't need to uninstall packages
                                    (for example on CI builds).
        --dry-run                   Print the `curl | tar` command that would be run to fetch the binary
    -V, --print-version             Print version info and exit
    -h, --help                      Prints help information
";

#[cfg_attr(test, derive(Debug))]
pub struct CliOptions {
    pub target: Option<String>,
    pub crate_names: Vec<Crate>,
    pub try_upstream: bool,
    pub fallback: bool,
    pub force: bool,
    pub no_binstall: bool,
    pub print_version: bool,
    pub help: bool,
    pub dry_run: bool,
}

#[cfg_attr(test, derive(Debug, Eq, PartialEq))]
pub struct Crate {
    pub name: String,
    pub version: Option<String>,
}

impl Crate {
    fn new(s: &str) -> Self {
        if let Some((name, version)) = s.split_once('@') {
            Self {
                name: name.to_string(),
                version: Some(version.to_string()),
            }
        } else {
            Self {
                name: s.to_string(),
                version: None,
            }
        }
    }
}

impl Crate {
    pub fn into_arg(self) -> String {
        let mut arg = self.name;

        if let Some(version) = self.version {
            arg.push('@');
            arg += version.as_str();
        }

        arg
    }
}

pub fn options_from_cli_args(
    mut args: pico_args::Arguments,
) -> Result<CliOptions, Box<dyn std::error::Error + Send + Sync + 'static>> {
    let version = args.opt_value_from_str("--version")?;

    let mut opts = CliOptions {
        target: args.opt_value_from_str("--target")?,
        try_upstream: args.contains("--try-upstream"),
        fallback: !args.contains("--no-fallback"),
        force: args.contains("--force"),
        no_binstall: args.contains("--no-binstall"),
        print_version: args.contains(["-V", "--print-version"]),
        help: args.contains(["-h", "--help"]),
        dry_run: args.contains("--dry-run"),
        // WARNING: We MUST parse all --options before parsing positional arguments,
        // because .subcommand() errors out if handed an arg with - at the start.
        crate_names: crate_names_from_positional_args(args)?,
    };

    if version.is_some() {
        match opts.crate_names.len().cmp(&1) {
            Ordering::Equal => opts.crate_names[0].version = version,
            Ordering::Greater => Err("You cannot specify `--version` in batch installation mode")?,
            _ => (),
        }
    }

    Ok(opts)
}

pub fn crate_names_from_positional_args(
    args: pico_args::Arguments,
) -> Result<Vec<Crate>, Box<dyn std::error::Error + Send + Sync + 'static>> {
    let args = args.finish();

    let args = args
        .iter()
        .map(|os_str| {
            os_str
                .to_str()
                .ok_or("Invalid crate names: Expected utf-8 strings")
        })
        .collect::<Result<Vec<_>, _>>()?;

    let mut check_for_slash = true;

    let args_to_skip = match args[..] {
        ["quickinstall", "--", ..] => {
            check_for_slash = false;
            2
        }
        ["quickinstall", ..] => 1,
        ["--", ..] => {
            check_for_slash = false;
            1
        }
        _ => 0,
    };

    args.into_iter()
        .skip(args_to_skip)
        .map(|arg| {
            if check_for_slash && arg.starts_with('-') {
                Err(format!("Invalid crate, crate name cannot starts with '-': {arg}").into())
            } else {
                Ok(Crate::new(arg))
            }
        })
        .collect()
}

#[cfg(test)]
mod test {
    use super::*;
    use std::ffi::OsString;

    const MOCK_CRATE_NAME: &str = "foo";
    const MOCK_CRATE_VERSION: &str = "3.14.15";
    const INVALID_FLAG: &str = "--an-invalid-flag";

    #[test]
    fn test_options_from_env() {
        let mock_cli_args: Vec<OsString> = [
            MOCK_CRATE_NAME,
            "--version",
            MOCK_CRATE_VERSION,
            "--dry-run",
        ]
        .iter()
        .map(OsString::from)
        .collect();
        let mock_pico_args = pico_args::Arguments::from_vec(mock_cli_args);

        let options = options_from_cli_args(mock_pico_args);
        let cli_options: CliOptions = options.unwrap();

        assert_eq!(
            [Crate {
                name: MOCK_CRATE_NAME.to_string(),
                version: Some(MOCK_CRATE_VERSION.to_string()),
            }]
            .as_slice(),
            cli_options.crate_names
        );
        assert!(cli_options.dry_run);
    }

    #[test]
    fn test_options_from_env_err() {
        let mock_cli_args: Vec<OsString> = vec![OsString::from(INVALID_FLAG)];
        let mock_pico_args = pico_args::Arguments::from_vec(mock_cli_args);

        let result = options_from_cli_args(mock_pico_args);
        assert!(result.is_err(), "{:#?}", result);
    }

    #[test]
    fn test_crate_name_from_positional_args() {
        let mock_cli_args: Vec<OsString> = vec![OsString::from(MOCK_CRATE_NAME)];
        let mock_pico_args = pico_args::Arguments::from_vec(mock_cli_args);

        let crate_name = crate_names_from_positional_args(mock_pico_args).unwrap();
        assert_eq!(
            [Crate {
                name: MOCK_CRATE_NAME.to_string(),
                version: None
            }]
            .as_slice(),
            crate_name
        );
    }

    #[test]
    fn test_crate_name_from_positional_args_err() {
        let mock_cli_args: Vec<OsString> = vec![
            OsString::from(MOCK_CRATE_NAME),
            OsString::from("cargo-quickinstall@0.2.7"),
        ];
        let mock_pico_args = pico_args::Arguments::from_vec(mock_cli_args);

        let crates = crate_names_from_positional_args(mock_pico_args).unwrap();

        assert_eq!(
            [
                Crate {
                    name: MOCK_CRATE_NAME.to_string(),
                    version: None
                },
                Crate {
                    name: "cargo-quickinstall".to_string(),
                    version: Some("0.2.7".to_string()),
                }
            ]
            .as_slice(),
            crates
        );
    }
}
