use home::cargo_home;
use std::{io, path::PathBuf};

pub fn utf8_to_string_lossy(bytes: Vec<u8>) -> String {
    String::from_utf8(bytes)
        .unwrap_or_else(|err| String::from_utf8_lossy(err.as_bytes()).into_owned())
}

pub fn get_cargo_bin_dir() -> io::Result<PathBuf> {
    cargo_home().map(|mut cargo_bin_dir| {
        cargo_bin_dir.push("bin");
        cargo_bin_dir
    })
}
