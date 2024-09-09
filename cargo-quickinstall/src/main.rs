// cargo-quickinstall is optimized so that bootstrapping with
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
use args::Crate;

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

    let crate_names = options.crate_names;

    if crate_names.is_empty() {
        Err(InstallError::MissingCrateNameArgument(args::USAGE))?
    }

    let target = options.target;

    let args = Args {
        dry_run: options.dry_run,
        try_upstream: options.try_upstream,
        fallback: options.fallback,
        force: options.force,
    };

    let f = if options.no_binstall {
        do_main_curl
    } else {
        do_main_binstall
    };

    f(crate_names, target, args)
}

#[derive(Default)]
struct Args {
    dry_run: bool,
    try_upstream: bool,
    fallback: bool,
    force: bool,
}

fn do_main_curl(
    crates: Vec<Crate>,
    target: Option<String>,
    args: Args,
) -> Result<(), Box<dyn std::error::Error + Send + Sync + 'static>> {
    let target = match target {
        Some(target) => target,
        None => get_target_triple()?,
    };

    for Crate {
        name: crate_name,
        version,
    } in crates
    {
        let version = match version {
            Some(version) => version,
            None => get_latest_version(&crate_name)?,
        };

        let crate_details = CrateDetails {
            crate_name,
            version,
            target: target.clone(),
        };

        if args.dry_run {
            let shell_cmd = do_dry_run_curl(&crate_details, args.fallback)?;
            println!("{}", shell_cmd);
        } else {
            let result = install_crate_curl(&crate_details, args.fallback);
            report_stats_in_background(&crate_details, &result);
            result?;
        }
    }

    Ok(())
}

fn do_main_binstall(
    mut crates: Vec<Crate>,
    target: Option<String>,
    args: Args,
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
        crates.retain(|crate_to_install| crate_to_install.name != "cargo-binstall");

        let args = Args {
            dry_run: args.dry_run,
            try_upstream: true,
            fallback: false,
            force: true,
        };

        download_and_install_binstall(args.dry_run)?;

        if args.dry_run {
            // cargo-binstall is not installed, so we print out the cargo-binstall
            // cmd and exit.
            println!("cargo binstall --no-confirm --force cargo-binstall");
            return do_install_binstall(crates, target, BinstallMode::PrintCmd, args);
        } else {
            println!(
                "Bootstrapping cargo-binstall with itself to make `cargo uninstall cargo-binstall` work properly"
            );
            do_install_binstall(
                vec![Crate {
                    name: "cargo-binstall".to_string(),
                    version: None,
                }],
                None,
                BinstallMode::Bootstrapping,
                args,
            )?;
        }
    }

    if crates.is_empty() {
        println!("No crate to install");

        Ok(())
    } else {
        do_install_binstall(crates, target, BinstallMode::Regular, args)
    }
}

fn download_and_install_binstall(
    dry_run: bool,
) -> Result<(), Box<dyn std::error::Error + Send + Sync + 'static>> {
    let target = get_target_triple()?;

    if dry_run {
        return match do_dry_run_download_and_install_binstall_from_upstream(&target) {
            Ok(shell_cmd) => {
                println!("{shell_cmd}");
                Ok(())
            }
            Err(err) if err.is_curl_404() => do_main_curl(
                vec![Crate {
                    name: "cargo-binstall".to_string(),
                    version: None,
                }],
                Some(target),
                Args {
                    dry_run: true,
                    ..Default::default()
                },
            ),
            Err(err) => Err(err.into()),
        };
    }

    match download_and_install_binstall_from_upstream(&target) {
        Err(err) if err.is_curl_404() => {
            println!(
                "Failed to install cargo-binstall from upstream, fallback to quickinstall: {err}"
            );

            do_main_curl(
                vec![Crate {
                    name: "cargo-binstall".to_string(),
                    version: None,
                }],
                Some(target),
                Args::default(),
            )
        }
        res => res.map_err(From::from),
    }
}

enum BinstallMode {
    Bootstrapping,
    Regular,
    PrintCmd,
}

fn do_install_binstall(
    crates: Vec<Crate>,
    target: Option<String>,
    mode: BinstallMode,
    args: Args,
) -> Result<(), Box<dyn std::error::Error + Send + Sync + 'static>> {
    let mut cmd = std::process::Command::new("cargo");

    cmd.arg("binstall").arg("--no-confirm").arg("--no-symlinks");

    if let Some(target) = target {
        cmd.arg("--targets").arg(target);
    }

    if args.force || matches!(mode, BinstallMode::Bootstrapping) {
        cmd.arg("--force");
    }

    if args.dry_run || matches!(mode, BinstallMode::PrintCmd) {
        cmd.arg("--dry-run");
    }

    if !args.try_upstream {
        cmd.args(["--disable-strategies", "crate-meta-data"]);
    }

    if !args.fallback {
        cmd.args(["--disable-strategies", "compile"]);
    }

    cmd.args(crates.into_iter().map(Crate::into_arg));

    if matches!(mode, BinstallMode::PrintCmd) {
        println!("{}", cmd.formattable());
        return Ok(());
    }

    println!("Calling `cargo-binstall` to do the install");

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
