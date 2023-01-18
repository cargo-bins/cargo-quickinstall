use home::cargo_home;
use once_cell::race::OnceBox;
use std::{
    io,
    ops::Deref,
    path::{Path, PathBuf},
};

pub fn utf8_to_string_lossy(bytes: Vec<u8>) -> String {
    String::from_utf8(bytes)
        .unwrap_or_else(|err| String::from_utf8_lossy(err.as_bytes()).into_owned())
}

pub fn get_cargo_bin_dir() -> io::Result<&'static Path> {
    static BIN_DIR: OnceBox<PathBuf> = OnceBox::new();

    BIN_DIR
        .get_or_try_init(|| {
            let mut cargo_bin_dir = cargo_home()?;
            cargo_bin_dir.push("bin");
            Ok(Box::new(cargo_bin_dir))
        })
        .map(Deref::deref)
}
