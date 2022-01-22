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

Non-default features are not supported.

## Original Problem Statement

`cargo quickinstall $package` should:

- [x] Attempt to fetch pre-compiled binaries for \$package if they exist.
  - [x] Report the download attempt to our stats server so we know what to build next.
  - [x] Download from github releases
  - [x] Unpack to `~/.cargo/bin`.
  - [ ] Somehow update `~/.cargo/.crates2.toml` and `~/.cargo/.crates2.json`?
- [x] Fall back to running `cargo install $package`.
  - [ ] Report statistics of how long it took to install, and how big the resulting binaries are.

The `cargo-quickinstall` crate should be as small and quick to install as possible, because the bootstrap time affects how useful it can be in CI jobs. 0-dependencies and a sub-1s build time would be ideal. Basically, `cargo-quickinstall` is just a glorified bash script at this point.

Currently it assumes that you have access to:

- tar
- curl

Both of these should exist on all recent Windows and MacOS installs. `curl` is available on most Linux systems, and is assumed to exist by the `rustup` installation instructions. I only plan to remove these dependencies if it can be done without increasing how long `cargo install cargo-quickinstall` takes (might be possible to do this using feature flags?).

There are a few pieces of infrastructure that are also part of this project:

- [x] A server for distributing the pre-built binaries
  - We are using github releases for this.
- [x] A server for report gathering
  - This is done using a vercel server that saves counts to redis.
- [x] A periodic task for building the most-requested packages for each OS/architecture
  - [ ] Get someone to audit my GitHub Actions sandboxing scheme.

## Contributing

There are a lot of things to figure out at the moment, so now is the perfect time to jump in and help. I created a [Gitter](https://gitter.im/cargo-quickinstall/community) room for collaborating in. You can also poke [@alsuren](https://twitter.com/alsuren) on Twitter or Discord. I'm also up for pairing over zoom to get new contributors onboarded.

Work is currently tracked on [the kanban board](https://github.com/alsuren/cargo-quickinstall/projects/1?fullscreen=true). It's a bit messy. Anything with more than one checkbox can be thought of as an epic. Smaller cards are often split out which duplicate parts of the epic, in order to focus my attention on a single small ticket when I look at the board. If you want help breaking down a card, give me a shout.

## Roadmap

This is mostly a proof of concept at the moment. If it is useful to people then I will propose including it in upstream cargo (at which point, the build time is less important). There is probably an intermediate step which involves using feature-flags to replace bash calls with rust libraries.
