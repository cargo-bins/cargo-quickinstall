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
        --dry-run                   Print the \"curl | tar\" command that would be run to fetch the binary
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

pub fn options_from_env() -> Result<CliOptions, Box<dyn std::error::Error + Send + Sync + 'static>>
{
    let mut args = pico_args::Arguments::from_env();
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
        Err(format!(
            "unexpected positional arguments: {}",
            unexpected
                .into_iter()
                .map(|s| s.to_string_lossy().to_string())
                .collect::<Vec<_>>()
                .join(" ")
        ))?
    }
    Ok(crate_name)
}
