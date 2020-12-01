# cargo-quickinstall

`cargo-quickinstall` is a bit like homebrew's concept of [Bottles (binary packages)](https://docs.brew.sh/Bottles), but for `cargo install`.

## Problem Statement

`cargo quickinstall $package` should:

- [x] Attempt to fetch precompiled binaries for \$package if they exist.
  - [x] Report the download attempt to our stats server so we know what to build next.
  - [x] Download from `bintray.com`.
  - [x] Unpack to `~/.cargo/bin`.
  - [ ] Somehow update `~/.cargo/.crates2.toml` and `~/.cargo/.crates2.json`?
- [ ] Fall back to running `cargo install $package`.
  - [ ] Report statistics of how long it took to install, and how big the resulting binaries are.

The `cargo-quickinstall` crate should be as small and quick to install as possible, because the bootstrap time affects how useful it can be in CI jobs. 0-dependencies and a sub-1s build time would be ideal. Basically, `cargo-quickinstall` is just a glorified bash script at this point.

Currently it assumes that you are on a unix-like machine and have access to:

- bash
- tar
- curl
- jq

If you can think of a way to remove any of these dependencies without incurring too much build-time cost, I would like to talk to you.

There are a few pieces of infrastructure that are also needed.

- [x] A server for distributing the pre-built binaries
  - I'm assuming that `bintray.com` is a good place for this.
- [x] A server for report gathering
  - This will be done using a stateless vercel server and a sematext log dump. I have most of this written already.
- [ ] A periodic task for building the most-requested packages for each OS/architecture
  - I have half an idea of how to do this, but I'm not sure how to sandbox the builds properly.
  - Until then, I will vet requested crates manually and make sure they are uploaded to https://bintray.com/cargo-quickinstall/cargo-quickinstall

## Contributing

There are a lot of things to figure out at the moment, so now is the perfect time to jump in and help. Poke [@alsuren](https://twitter.com/alsuren) on Twitter or Discord if you want to pair on anything.

## Roadmap

This is mostly a proof of concept at the moment. If it is useful to people then I will propose including it in upstream cargo (at which point, the build time is less important). There is probably an intermediate step which involves using feature-flags to replace bash calls with rust libraries.
