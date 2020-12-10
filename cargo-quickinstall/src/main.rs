// cargo-quickinstall is optimised so that bootstrapping with
//
//     cargo install cargo-quickinstall
//
// is quick. It's basically a glorified bash script.
//
// I suspect that there will be ways to clean this up without increasing
// the bootstrapping time too much. Patches to do this would be very welcome.

use tinyjson::JsonValue;
use std::io::{Error, ErrorKind};

fn bash_stdout(command_string: &str) -> std::io::Result<String> {
    let command_string = format!("set -euo pipefail && {}", command_string);
    let output = std::process::Command::new("bash")
        .arg("-c")
        .arg(&command_string)
        .output()?;

    if !output.status.success() {
        println!("{:?} => {:#?}", command_string, output);
        return Err(std::io::Error::new(
            std::io::ErrorKind::Other,
            "Command failed",
        ));
    }

    let mut stdout = String::from_utf8(output.stdout).unwrap();
    let len = stdout.trim_end_matches('\n').len();
    stdout.truncate(len);
    Ok(stdout)
}

fn get_latest_version(crate_name: &str) -> std::io::Result<String> {
    let command_string = format!(
        "curl \
            --user-agent 'cargo-quickinstall build pipeline (alsuren@gmail.com)' \
            --location \
            --fail \
            'https://crates.io/api/v1/crates/{}'",
        crate_name
    );
    let stdout =  bash_stdout(&command_string)?;
    let parsed: Result<JsonValue, Error> = match stdout.parse() {
        Ok(parsed) => Ok(parsed),
        Err(_) => Err(Error::new(ErrorKind::InvalidData, "Unable to parse JSON."))
    };
    let mut version: String = parsed?["versions"][0]["num"].stringify().unwrap();
    version.remove(0);
    version.remove(version.len()-1);
    Ok(version)
}

fn get_target_triple() -> std::io::Result<String> {
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

fn install_crate(crate_name: &str, version: &str, target: &str) -> std::io::Result<()> {
    let tarball_name = format!("{}-{}-{}.tar.gz", crate_name, version, target);

    let download_url = format!(
        "https://dl.bintray.com/cargo-quickinstall/cargo-quickinstall/{}",
        tarball_name
    );
    let install_command = format!(
        "curl --location --fail '{}' | tar -xzvvf - -C ~/.cargo/bin 2>&1",
        download_url
    );
    match bash_stdout(&install_command) {
        Ok(tar_output) => println!(
            "Installed {} {} to ~/.cargo/bin:\n{}",
            crate_name, version, tar_output
        ),
        Err(err) => {
            println!(
                "Got {:?} when trying to install. Falling back to `cargo install`.",
                err
            );
            println!("We have reported your installation request, so it should be built soon.");

            if !std::process::Command::new("cargo")
                .arg("install")
                .arg(crate_name)
                .status()?
                .success()
            {
                println!("hrm. `cargo install` didn't work either. Looks like you're on your own.");
                std::process::exit(1)
            }
        }
    }

    Ok(())
}

fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync + 'static>> {
    let args = std::env::args().collect::<Vec<_>>();
    let crate_name = if let Some(true) = args.get(1).map(|a| a == "quickinstall") {
        args.get(2)
    } else {
        args.get(1)
    };

    let crate_name = crate_name.ok_or("USAGE: cargo quickinsall CRATE_NAME")?;
    let version = get_latest_version(crate_name)?;
    let target = get_target_triple()?;

    let stats_handle = report_stats_in_background(crate_name, &version, &target);
    install_crate(crate_name, &version, &target)?;
    stats_handle.join().unwrap();

    Ok(())
}
