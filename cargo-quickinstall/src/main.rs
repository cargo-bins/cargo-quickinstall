// cargo-quickinstall is optimised so that bootstrapping with
//
//     cargo install cargo-quickinstall
//
// is quick. It's basically a glorified bash script.
//
// I suspect that there will be ways to clean this up without increasing
// the bootstrapping time too much. Patches to do this would be very welcome.

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
        "curl --location --fail 'https://crates.io/api/v1/crates/{}' | jq -r .versions[0].num",
        crate_name
    );
    bash_stdout(&command_string)
}

fn get_target_triple() -> std::io::Result<String> {
    // In theory I should ve using `rustup show active-toolchain` but that is
    // slightly more difficult to parse than `rustc --print sysroot` and I'm
    // not sure if it's available on all systems.
    // Send me a patch if this breaks for you.
    bash_stdout("rustc --print sysroot | grep --only-matching '[^-]*-[^-]*-[^-]*$'")
}

fn install_crate(crate_name: &str, version: &str, target: &str) -> std::io::Result<()> {
    let download_url = format!(
        "https://dl.bintray.com/cargo-quickinstall/cargo-quickinstall/{}-{}-{}.tar.gz",
        crate_name, version, target
    );
    let command_string = format!(
        "curl --location --fail '{}' | tar -xzvvf - -C ~/.cargo/bin 2>&1",
        download_url
    );
    let tar_output = bash_stdout(&command_string)?;

    println!(
        "Installed {} {} to ~/.cargo/bin:\n{}",
        crate_name, version, tar_output
    );

    Ok(())
}

fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync + 'static>> {
    let args = std::env::args().collect::<Vec<_>>();
    let crate_name = if args[0] == "cargo" {
        assert_eq!(args[1], "quickinstall");
        args.get(2)
    } else if args[0].ends_with("cargo-quickinstall") {
        args.get(1)
    } else {
        dbg!(args);
        unreachable!("cargo should run our binary with quickinstall as the first argument")
    };

    let crate_name = crate_name.ok_or("USAGE: cargo quickinsall CRATE_NAME")?;
    let version = get_latest_version(crate_name)?;
    let target = get_target_triple()?;

    install_crate(crate_name, &version, &target)?;

    Ok(())
}
