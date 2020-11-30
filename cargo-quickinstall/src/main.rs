// cargo-quickinstall is optimised so that bootstrapping with
//
//     cargo install cargo-quickinstall
//
// is quick. It's basically a glorified bash script.
//
// I suspect that there will be ways to clean this up without increasing
// the bootstrapping time too much. Patches to do this would be very welcome.

fn get_latest_version(crate_name: &str) -> std::io::Result<String> {
    let command_string = format!(
        "set -euxo pipefail && curl --location --fail 'https://crates.io/api/v1/crates/{}' | jq -r .versions[0].num",
        crate_name
    );
    let output = std::process::Command::new("bash")
        .arg("-c")
        .arg(command_string)
        .output()?;

    let mut version = String::from_utf8(output.stdout).unwrap();
    version.retain(|c| !c.is_ascii_whitespace());
    Ok(version)
}

fn get_target_triple() -> std::io::Result<String> {
    let command_string =
        "set -euxo pipefail && rustc --print sysroot | grep --only-matching '[^-]*-[^-]*-[^-]*$'";
    let output = std::process::Command::new("bash")
        .arg("-c")
        .arg(command_string)
        .output()?;

    let mut triple = String::from_utf8(output.stdout).unwrap();
    triple.retain(|c| !c.is_ascii_whitespace());
    Ok(triple)
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

    let download_url = format!(
        "https://dl.bintray.com/cargo-quickinstall/cargo-quickinstall/{}-{}-{}.tar.gz",
        crate_name, version, target
    );
    let command_string = format!(
        "set -euxo pipefail && cd ~/.cargo/bin && curl --location --fail '{}' | tar -xzvf -",
        download_url
    );
    std::process::Command::new("bash")
        .arg("-c")
        .arg(command_string)
        .status()
        .map_err(|e| format!("{:?}", e))?;

    Ok(())
}
