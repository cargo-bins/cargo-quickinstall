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
    let version = match options.version {
        Some(version) => version,
        None => get_latest_version(&crate_name)?,
    };
    let target = match options.target {
        Some(target) => target,
        None => get_target_triple()?,
    };

    let crate_details = CrateDetails {
        crate_name,
        version,
        target,
    };

    if options.dry_run {
        let shell_cmd = do_dry_run(&crate_details);
        println!("{}", shell_cmd);
        return Ok(());
    }

    let stats_handle = report_stats_in_background(&crate_details);
    install_crate(&crate_details, options.fallback)?;
    stats_handle.join().unwrap();

    Ok(())
}
