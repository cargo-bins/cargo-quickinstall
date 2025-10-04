# cargo-quickinstall

[![Crates.io](https://img.shields.io/crates/v/cargo-quickinstall.svg)](https://crates.io/crates/cargo-quickinstall)
[![Join the chat at https://gitter.im/cargo-quickinstall/community](https://badges.gitter.im/cargo-quickinstall/community.svg)](https://gitter.im/cargo-quickinstall/community?utm_source=badge&utm_medium=badge&utm_campaign=pr-badge&utm_content=badge)

`cargo-quickinstall` is a bit like Homebrew's concept of [Bottles (binary packages)](https://docs.brew.sh/Bottles), but for `cargo install`.

## Installation

    cargo install cargo-quickinstall

Recent versions of Windows, MacOS and Linux are supported.

## Usage

Whenever you would usually write something like:

    cargo install ripgrep

you can now write:

    cargo quickinstall ripgrep

This will install pre-compiled versions of any binaries in the crate. If we don't have a pre-compiled version, it will fallback to `cargo install` automatically.

## Relationship to `cargo-binstall`

[`cargo-binstall`](https://crates.io/crates/cargo-binstall) (from version 0.6.2 onwards) is also capable of fetching packages from the cargo-quickinstall github releases repo. `cargo-binstall` is an excellent piece of software. If you're looking for something for desktop use, I can recommend using `cargo-binstall`.

## Use in CI systems

If you want to install a rust package on a CI system, you can do it with a `curl | tar` command, directly from the `cargo-quickinstall` github releases repo.

```bash
cargo-quickinstall --dry-run --no-binstall ripgrep
```

will print:

```bash
curl --user-agent "cargo-quickinstall/0.3.13 client (alsuren@gmail.com)" --location --silent --show-error --fail "https://github.com/cargo-bins/cargo-quickinstall/releases/download/ripgrep-14.1.1/ripgrep-14.1.1-aarch64-apple-darwin.tar.gz" | tar -xzvvf - -C /Users/alsuren/.cargo/bin
```

Edit the command however you need, and paste it into your CI pipeline.

## Supported targets

Check [supported-targets](/supported-targets) for lists of targets quickinstall
can build for.

## Limitations

Non-default features are not supported.

The `cargo-quickinstall` client is just a glorified bash script at this point.

Currently it assumes that you have access to:

- tar
- curl

Both of these should exist on all recent Windows and MacOS installs. `curl` is available on most Linux systems, and is assumed to exist by the `rustup` installation instructions. I only plan to remove these runtime dependencies if it can be done without increasing how long `cargo install cargo-quickinstall` takes (might be possible to do this using feature flags?).

There are a few pieces of infrastructure that are also part of this project:

- [x] A server for distributing the pre-built binaries
  - We are using github releases for this.
- [x] A server for report gathering
  - This is done using a vercel server that saves counts to redis.
- [x] A periodic task for building the most-requested packages for each OS/architecture
  - [ ] Get someone to audit my GitHub Actions sandboxing scheme.

## Contributing

There are a lot of things to figure out at the moment, so now is the perfect time to jump in and help. I created a [Gitter](https://gitter.im/cargo-quickinstall/community) room for collaborating in. You can also poke [@alsuren](https://x.com/alsuren) on X/Twitter or Discord. I'm also up for pairing over zoom to get new contributors onboarded.

Work is currently tracked on [the kanban board](https://github.com/orgs/cargo-bins/projects/1). If you want help breaking down a ticket, give me a shout in one of the above places.

## Releasing

Releasing of patch versions is handled by the makefile, so can be done by:

```bash
make release
```

If you need to make a major version bump then copy-paste the commands out of the Makefile.

Once a release has been made, post about it on [the rust forums](https://users.rust-lang.org/c/announcements/6), [reddit](https://www.reddit.com/r/rust/) and x/twitter.

## License

Copyright (c) 2020-2025 cargo-quickinstall developers

`cargo-quickinstall` is made available under the terms of either the MIT License or the Apache License 2.0, at your option.

See the [LICENSE-APACHE](LICENSE-APACHE) and [LICENSE-MIT](LICENSE-MIT) files for license details.
