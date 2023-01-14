use home::cargo_home;
use std::{io, path::PathBuf};

pub fn utf8_to_string_lossy(bytes: Vec<u8>) -> String {
    String::from_utf8(bytes)
        .unwrap_or_else(|err| String::from_utf8_lossy(err.as_bytes()).into_owned())
}

pub fn get_cargo_bin_dir() -> io::Result<PathBuf> {
    let mut cargo_bin_dir = cargo_home()?;
    cargo_bin_dir.push("bin");
    Ok(cargo_bin_dir)
}
