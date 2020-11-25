# cargo-quickinstall

`cargo-quickinstall` is a bit like homebrew's concept of [Bottles (binary packages)](https://docs.brew.sh/Bottles), but for `cargo install`.

## Problem Statement

`cargo quickinstall $package` should:

- [ ] Attempt to fetch precompiled binaries for \$package if they exist.
  - [ ] Download from `bintray.com`.
  - [ ] Check signatures and unpack.
  - [ ] Somehow update `~/.cargo/.crates2.toml` and `~/.cargo/.crates2.json`?
- [ ] Fall back to running `cargo install $package`.
  - [ ] Report statistics of how long it took to install, and how big the resulting binaries are.

The `cargo-quickinstall` crate should be as small and quick to install as possible, because the bootstrap time affects how useful it can be in CI jobs. 0-dependencies and a sub-1s build time would be ideal.

It seems reasonable to rely on a `curl` executable being available on the system, so that we don't have to depend on an http library. It would also be reasonable to make the `cargo-quickinstall` crate be a glorified shell shell script, that bootstraps itself on first-run by downloading some kind of `cargo-quickinstall-for-real` binary.

There are a few pieces of infrastructure that are also needed.

- [ ] A server for distributing the pre-built binaries
  - I'm assuming that `bintray.com` will be a good place for this.
- [ ] A server for report gathering
  - It feels like this should already exist. How do botnets do it?
- [ ] A periodic task for building the most-requested packages for each OS/architecture
  - I think that this can be done with github actions periodic tasks?

## Contributing

There are a lot of things to figure out at the moment, so now is the perfect time to jump in and help. I would especially like help finding a statistics gathering server and thinking up a punny name for the pre-compiled crates.
