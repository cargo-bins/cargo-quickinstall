//! Builds a static OpenSSL 3 and OpenSSL 4 with openssl-src for every target
//! in OPENSSL_TARGETS (separated by spaces) into OPENSSL_PREFIX/3/<target> and
//! OPENSSL_PREFIX/4/<target>.
//!
//! Both, because openssl-sys only accepts OpenSSL 4 since 0.9.114, and the
//! build script of an older one, which many crates still have in their
//! lockfile, aborts on it. build-crate.sh picks one by that version.
//!
//! It runs as a build script so that the `make` of every target shares
//! cargo's jobserver, and the targets build at the same time.
//!
//! The C compiler is zig, through `cargo-zigbuild zig cc` like the crate
//! builds in the sandbox, which takes care of zig's quirks. The gnu targets
//! are for glibc 2.17, like build-version.sh.

use std::{env, fs, os::unix::fs::PermissionsExt, path::Path, path::PathBuf, thread};

/// The zig target and extra compiler flags for a Rust target, the way
/// cargo-zigbuild passes them.
fn zig_target(target: &str) -> (&'static str, &'static str) {
    const ARMV7: &str = "-mcpu=generic+v7a+vfp3-d32+thumb2-neon";
    match target {
        "x86_64-unknown-linux-gnu" => ("x86_64-linux-gnu.2.17", ""),
        "x86_64-unknown-linux-musl" => ("x86_64-linux-musl", ""),
        "aarch64-unknown-linux-gnu" => ("aarch64-linux-gnu.2.17", ""),
        "aarch64-unknown-linux-musl" => ("aarch64-linux-musl", ""),
        "armv7-unknown-linux-gnueabihf" => ("arm-linux-gnueabihf.2.17", ARMV7),
        "armv7-unknown-linux-musleabihf" => ("arm-linux-musleabihf", ARMV7),
        _ => panic!("no zig target for {target}"),
    }
}

/// Writes a shell script that runs `command` into OUT_DIR, and returns its
/// path, since cc reads a single program from CC_<target>, AR_<target> and
/// RANLIB_<target>.
fn script(name: &str, command: &str) -> PathBuf {
    let path = Path::new(&env::var_os("OUT_DIR").unwrap()).join(name);
    fs::write(&path, format!("#!/bin/sh\nexec {command} \"$@\"\n")).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    path
}

fn main() {
    println!("cargo::rerun-if-env-changed=OPENSSL_TARGETS");
    println!("cargo::rerun-if-env-changed=OPENSSL_PREFIX");
    let targets = env::var("OPENSSL_TARGETS").expect("OPENSSL_TARGETS is not set");
    let targets: Vec<&str> = targets.split_whitespace().collect();
    let prefix = PathBuf::from(env::var_os("OPENSSL_PREFIX").expect("OPENSSL_PREFIX is not set"));
    let out_dir = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let host = env::var("HOST").unwrap();

    let ar = script("ar.sh", "cargo-zigbuild zig ar --");
    let ranlib = script("ranlib.sh", "cargo-zigbuild zig ranlib --");
    for target in &targets {
        let (zig_target, flags) = zig_target(target);
        let cc = script(
            &format!("cc-{target}.sh"),
            &format!("cargo-zigbuild zig cc -- -fno-sanitize=all {flags} -target {zig_target}"),
        );
        let target = target.replace('-', "_");
        // SAFETY: no other thread is running yet.
        unsafe {
            env::set_var(format!("CC_{target}"), &cc);
            env::set_var(format!("AR_{target}"), &ar);
            env::set_var(format!("RANLIB_{target}"), &ranlib);
        }
    }

    fs::create_dir_all(prefix.join("3")).unwrap();
    fs::create_dir_all(prefix.join("4")).unwrap();
    // References, for the threads to copy.
    let (out_dir, host, prefix) = (&out_dir, host.as_str(), &prefix);
    // The same builder, from either version of openssl-src.
    macro_rules! build {
        ($openssl_src:ident, $major:literal, $target:expr) => {{
            let target: &str = $target;
            let build = out_dir.join(format!("{}-{target}", $major));
            $openssl_src::Build::new()
                .target(target)
                .host(host)
                .out_dir(&build)
                .build();
            fs::rename(build.join("install"), prefix.join($major).join(target)).unwrap();
        }};
    }

    thread::scope(|s| {
        for &target in &targets {
            s.spawn(move || build!(openssl_src_3, "3", target));
            s.spawn(move || build!(openssl_src_4, "4", target));
        }
    });
}
