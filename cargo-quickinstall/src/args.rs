pub const USAGE: &str = "USAGE:
    cargo quickinstall [OPTIONS] -- CRATE_NAME

For more information try --help
";
pub const HELP: &str = "USAGE:
    cargo quickinstall [OPTIONS] -- CRATE_NAME

OPTIONS:
        --version <VERSION>         Specify a version to install
        --target <TRIPLE>           Install package for the target triple
        --no-fallback               Don't fall back to `cargo install`
        --dry-run                   Print the `curl | tar` command that would be run to fetch the binary
    -V, --print-version             Print version info and exit
    -h, --help                      Prints help information
";

pub struct CliOptions {
    pub version: Option<String>,
    pub target: Option<String>,
    pub crate_name: Option<String>,
    pub fallback: bool,
    pub print_version: bool,
    pub help: bool,
    pub dry_run: bool,
}

pub fn options_from_cli_args(
    mut args: pico_args::Arguments,
) -> Result<CliOptions, Box<dyn std::error::Error + Send + Sync + 'static>> {
    Ok(CliOptions {
        version: args.opt_value_from_str("--version")?,
        target: args.opt_value_from_str("--target")?,
        fallback: !args.contains("--no-fallback"),
        print_version: args.contains(["-V", "--print-version"]),
        help: args.contains(["-h", "--help"]),
        dry_run: args.contains("--dry-run"),
        // WARNING: We MUST parse all --options before parsing positional arguments,
        // because .subcommand() errors out if handed an arg with - at the start.
        crate_name: crate_name_from_positional_args(args)?,
    })
}

pub fn crate_name_from_positional_args(
    mut args: pico_args::Arguments,
) -> Result<Option<String>, Box<dyn std::error::Error + Send + Sync + 'static>> {
    // handle this pattern: `cargo quickinstall -- crate`
    let crate_name = if let Some(crate_name) = args.opt_value_from_str("--")? {
        Some(crate_name)
    } else {
        match args.subcommand()? {
            // Handle how `cargo quickinstall $args` causes us to be called as `cargo-quickinstall quickinstall $args`
            Some(arg) if arg == "quickinstall" => args.subcommand()?,
            arg => arg,
        }
    };
    let unexpected = args.finish();

    if !unexpected.is_empty() {
        return Err(format!(
            "unexpected positional arguments: {}",
            unexpected
                .into_iter()
                .map(|s| s.to_string_lossy().to_string())
                .collect::<Vec<_>>()
                .join(" ")
        )
        .into());
    }
    Ok(crate_name)
}

#[cfg(test)]
mod test {
    use super::*;
    use std::ffi::OsString;

    const MOCK_CRATE_NAME: &str = "foo";
    const MOCK_CRATE_VERSION: &str = "3.14.15";
    const REDUNDANT_ARG: &str = "bar";
    const INVALID_FLAG: &str = "--an-invalid-flag";

    #[test]
    fn test_options_from_env() {
        let mock_cli_args: Vec<OsString> = vec![
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

        assert_eq!(MOCK_CRATE_NAME, cli_options.crate_name.unwrap());
        assert_eq!(MOCK_CRATE_VERSION, cli_options.version.unwrap());
        assert!(cli_options.dry_run);
    }

    #[test]
    fn test_options_from_env_err() {
        let mock_cli_args: Vec<OsString> = vec![OsString::from(INVALID_FLAG)];
        let mock_pico_args = pico_args::Arguments::from_vec(mock_cli_args);

        let result = options_from_cli_args(mock_pico_args);
        assert!(result.is_err());
    }

    #[test]
    fn test_crate_name_from_positional_args() {
        let mock_cli_args: Vec<OsString> = vec![OsString::from(MOCK_CRATE_NAME)];
        let mock_pico_args = pico_args::Arguments::from_vec(mock_cli_args);

        let crate_name = crate_name_from_positional_args(mock_pico_args).unwrap();
        assert_eq!(MOCK_CRATE_NAME, crate_name.unwrap());
    }

    #[test]
    fn test_crate_name_from_positional_args_err() {
        let mock_cli_args: Vec<OsString> = vec![
            OsString::from(MOCK_CRATE_NAME),
            OsString::from(REDUNDANT_ARG),
        ];
        let mock_pico_args = pico_args::Arguments::from_vec(mock_cli_args);

        let result = crate_name_from_positional_args(mock_pico_args);
        assert!(result.is_err());
    }
}
