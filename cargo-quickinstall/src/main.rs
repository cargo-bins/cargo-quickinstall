// cargo-quickinstall is optimised so that bootstrapping with
//
//     cargo install cargo-quickinstall
//
// is quick. It's basically a glorified bash script.
//
// I suspect that there will be ways to clean this up without increasing
// the bootstrapping time too much. Patches to do this would be very welcome.
fn main() -> Result<(), String> {
    println!("Hello, world!");
    let crate_name = "ripgrep";
    let version = "12.1.1";
    // FIXME: `rustc --print sysroot | grep --only-matching '[^-]*-[^-]*-[^-]*$'` or something
    let target = "x86_64-apple-darwin";
    let download_url = format!(
        "https://dl.bintray.com/cargo-quickinstall/cargo-quickinstall/{}-{}-{}.tar.gz",
        crate_name, version, target
    );
    let commands = format!(
        "set -euxo pipefail && cd ~/.cargo/bin && curl --fail --location {} | tar -xzvf -",
        download_url
    );
    std::process::Command::new("bash")
        .arg("-c")
        .arg(commands)
        .status()
        .map_err(|e| format!("{:?}", e))?;

    Ok(())
}
