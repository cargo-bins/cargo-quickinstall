// cargo-quickinstall is optimised so that bootstrapping with
//
//     cargo install cargo-quickinstall
//
// is quick. It's basically a glorified bash script.
//
// I suspect that there will be ways to clean this up without increasing
// the bootstrapping time too much. Patches to do this would be very welcome.

use cargo_quickinstall::install_error::*;
use cargo_quickinstall::*;

mod args;

fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync + 'static>> {
    let options = args::options_from_cli_args(pico_args::Arguments::from_env())?;

    if options.print_version {
        println!(
            "`cargo quickinstall` version: {}",
            env!("CARGO_PKG_VERSION")
        );
        return Ok(());
    }

    if options.help {
        println!("{}", args::HELP);
        return Ok(());
    }

    let crate_name = options
        .crate_name
        .ok_or(InstallError::MissingCrateNameArgument(args::USAGE))?;

    let version = options.version;
    let target = options.target;

    let f = if options.no_binstall {
        do_main_curl
    } else {
        do_main_binstall
    };

    f(
        crate_name,
        version,
        target,
        options.dry_run,
        options.fallback,
    )
}

fn do_main_curl(
    crate_name: String,
    version: Option<String>,
    target: Option<String>,
    dry_run: bool,
    fallback: bool,
) -> Result<(), Box<dyn std::error::Error + Send + Sync + 'static>> {
    let target = match target {
        Some(target) => target,
        None => get_target_triple()?,
    };

    let version = match version {
        Some(version) => version,
        None => get_latest_version(&crate_name)?,
    };

    let crate_details = CrateDetails {
        crate_name,
        version,
        target,
    };

    if dry_run {
        let shell_cmd = do_dry_run_curl(&crate_details)?;
        println!("{}", shell_cmd);
        return Ok(());
    }

    report_stats_in_background(&crate_details);
    install_crate_curl(&crate_details, fallback)?;

    Ok(())
}

struct Crate {
    name: String,
    version: Option<String>,
}

impl Crate {
    fn into_arg(self) -> String {
        let mut arg = self.name;

        if let Some(version) = self.version {
            arg.push('@');
            arg += version.as_str();
        }

        arg
    }
}

fn do_main_binstall(
    crate_name: String,
    version: Option<String>,
    target: Option<String>,
    dry_run: bool,
    _fallback: bool,
) -> Result<(), Box<dyn std::error::Error + Send + Sync + 'static>> {
    let is_binstall_compatible = get_cargo_binstall_version()
        .map(
            |binstall_version| match binstall_version.splitn(3, '.').collect::<Vec<_>>()[..] {
                [major, minor, _] => {
                    // If >=1.0.0
                    major != "0"
                            // Or >=0.17.0
                            || minor
                                .parse::<u64>()
                                .map(|minor| minor >= 17)
                                .unwrap_or(false)
                }
                _ => false,
            },
        )
        .unwrap_or(false);

    if !is_binstall_compatible {
        download_and_install_binstall(dry_run)?;

        if !dry_run {
            println!(
                "Bootstrapping cargo-binstall with itself to make `cargo uninstall ` work properly"
            );
            do_install_binstall(
                vec![Crate {
                    name: "cargo-binstall".to_string(),
                    version: None,
                }],
                None,
                BinstallMode::Bootstrapping,
            )?;
        } else {
            return Ok(());
        }
    }

    do_install_binstall(
        vec![Crate {
            name: crate_name,
            version,
        }],
        target,
        BinstallMode::Regular { dry_run },
    )
}

fn download_and_install_binstall(
    dry_run: bool,
) -> Result<(), Box<dyn std::error::Error + Send + Sync + 'static>> {
    let target = get_target_triple()?;

    if dry_run {
        let shell_cmd = do_dry_run_download_and_install_binstall_from_upstream(&target)?;
        println!("{shell_cmd}");
        return Ok(());
    }

    match download_and_install_binstall_from_upstream(&target) {
        Err(err) if err.is_curl_404() => {
            println!(
                "Failed to install cargo-binstall from upstream, fallback to quickinstall: {err}"
            );

            do_main_curl(
                "cargo-binstall".to_string(),
                None,
                Some(target),
                false,
                false,
            )
        }
        res => res.map_err(From::from),
    }
}

enum BinstallMode {
    Bootstrapping,
    Regular { dry_run: bool },
}

fn do_install_binstall(
    crates: Vec<Crate>,
    target: Option<String>,
    mode: BinstallMode,
) -> Result<(), Box<dyn std::error::Error + Send + Sync + 'static>> {
    let mut cmd = std::process::Command::new("cargo");

    cmd.arg("binstall").arg("--no-confirm");

    if let Some(target) = target {
        cmd.arg("--targets").arg(target);
    }

    if matches!(mode, BinstallMode::Bootstrapping) {
        cmd.arg("--force");
    }

    if let BinstallMode::Regular { dry_run: true } = mode {
        cmd.arg("--dry-run");
    }

    cmd.args(crates.into_iter().map(Crate::into_arg));

    #[cfg(unix)]
    if !matches!(mode, BinstallMode::Bootstrapping) {
        return Err(std::os::unix::process::CommandExt::exec(&mut cmd).into());
    }

    let status = cmd.status()?;

    if !status.success() {
        Err(format!("`{}` failed with {status}", cmd.formattable(),).into())
    } else {
        Ok(())
    }
}
