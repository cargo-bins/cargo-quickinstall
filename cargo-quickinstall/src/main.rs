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
        let shell_cmd = do_dry_run_curl(&crate_details);
        println!("{}", shell_cmd);
        return Ok(());
    }

    let stats_handle = report_stats_in_background(&crate_details);
    install_crate_curl(&crate_details, fallback)?;
    stats_handle.join().unwrap();

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
    fallback: bool,
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
        do_main_curl("cargo-binstall".to_string(), None, None, dry_run, fallback)?;

        if !dry_run {
            println!("Bootstrapping cargo-binstall with itself to make `cargo uninstall ` work properly");
            do_install_binstall(
                vec![Crate {
                    name: "cargo-binstall".to_string(),
                    version: None,
                }],
                None,
                false,
                true,
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
        dry_run,
        false,
    )
}

fn do_install_binstall(
    crates: Vec<Crate>,
    target: Option<String>,
    dry_run: bool,
    force: bool,
) -> Result<(), Box<dyn std::error::Error + Send + Sync + 'static>> {
    let mut cmd = std::process::Command::new("cargo");

    cmd.arg("binstall").arg("--no-confirm");

    if let Some(target) = target {
        cmd.arg("--targets").arg(target);
    }

    if force {
        cmd.arg("--force");
    }

    if dry_run {
        cmd.arg("--dry-run");
    }

    cmd.args(crates.into_iter().map(Crate::into_arg));

    let status = cmd.status()?;

    if !status.success() {
        Err(format!(
            "`{} {}` failed with {status}",
            cmd.get_program().to_string_lossy(),
            cmd.get_args()
                .map(|arg| arg.to_string_lossy())
                .collect::<Vec<_>>()
                .join(" "),
        )
        .into())
    } else {
        Ok(())
    }
}
