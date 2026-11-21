# Image that build-crate.sh runs in for Linux targets, see build-version.sh.
#
# .github/workflows/sandbox-image.yml builds it on main and publishes it to
# GHCR, tagged by sandbox/image-tag.sh. build-version.sh pulls that image, or
# builds this file itself, before any crate code runs, when it is not
# published yet. Never build it in a job that has run crate code, and never
# keep it in the Actions cache: crate code running on the macOS and Windows
# runners can write to that cache, so it could poison the image there.
#
# The base is an Ubuntu LTS. .github/dependabot.yml ignores the interim
# releases, so Dependabot moves it from one LTS to the next. Without that it
# would propose releases such as 25.10, and its cooldown even favours the
# end-of-life ones, since those tags are no longer rebuilt.
FROM ubuntu:26.04@sha256:d66b366dac61b575bee2aef07e9c26e8070096fbe84a3d4d3eb0da069b5d76db

LABEL org.opencontainers.image.source=https://github.com/cargo-bins/cargo-quickinstall
LABEL org.opencontainers.image.description="Sandbox that cargo-quickinstall builds crates in"

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential ca-certificates clang cmake curl file git jq lld llvm \
        nasm ninja-build perl pkg-config protobuf-compiler python3 python3-venv \
        unzip xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Read-only at run time. The build gets its own CARGO_HOME.
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo
ENV PATH=/opt/zigbuild/bin:/opt/cargo/bin:$PATH
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
# The first field of sandbox/image-tag.sh's output.
ARG RUST_TOOLCHAIN=stable
COPY supported-targets /opt/supported-targets
RUN url="https://static.rust-lang.org/rustup/dist/$(uname -m)-unknown-linux-gnu/rustup-init" \
    && curl --proto '=https' --tlsv1.2 -sSf -o /tmp/rustup-init "$url" \
    && echo "$(curl --proto '=https' --tlsv1.2 -sSf "$url.sha256" | cut -d' ' -f1)  /tmp/rustup-init" | sha256sum -c - \
    && chmod +x /tmp/rustup-init \
    && /tmp/rustup-init -y --profile minimal --default-toolchain "$RUST_TOOLCHAIN" --no-modify-path \
    && rm /tmp/rustup-init \
    && rustup target add $(tr -s ' ' '\n' < /opt/supported-targets | grep -- '-linux-') \
    && chmod -R a+rX "$RUSTUP_HOME" "$CARGO_HOME"

COPY zigbuild-requirements.txt /opt/zigbuild-requirements.txt
RUN python3 -m venv /opt/zigbuild \
    && /opt/zigbuild/bin/pip install --no-cache-dir -r /opt/zigbuild-requirements.txt \
    && chmod -R a+rwX /opt/zigbuild

# A static OpenSSL for every Linux target, in /opt/openssl/<target>, that
# build-crate.sh points openssl-sys at. Builds run with PKG_CONFIG set to a
# script that always fails, so without this every crate that has openssl-sys
# among its dependencies, but no `vendored` feature of its own, fails to build.
# openssl-src builds it the way its `vendored` feature does, with zig as the
# compiler like the crate builds, and for glibc 2.17 like build-version.sh.
COPY sandbox/openssl /tmp/openssl
RUN cd /tmp/openssl \
    && targets="$(tr -s ' ' '\n' < /opt/supported-targets | grep -- '-linux-')" \
    && /opt/zigbuild/bin/cargo-zigbuild zigbuild --locked --release \
        $(for t in $targets; do case "$t" in *-gnu*) t="$t.2.17" ;; esac; echo "--target $t"; done) \
    && mkdir /opt/openssl \
    && for t in $targets; do \
        libssl="$(find "target/$t/release/build" -path '*/openssl-build/install/lib/libssl.a')"; \
        test "$(wc -l <<<"$libssl")" = 1 -a -f "$libssl" || { echo "no libssl.a for $t"; exit 1; }; \
        cp -R "$(dirname "$(dirname "$libssl")")" "/opt/openssl/$t" || exit 1; \
    done \
    && llvm-strip --strip-debug /opt/openssl/*/lib/*.a \
    && chmod -R a+rX /opt/openssl \
    && cd / && rm -rf /tmp/openssl "$CARGO_HOME/registry" "$HOME/.cache"

# cargo-zigbuild patches zig's libc headers for some targets (such as
# arm-features.h for armv7 glibc), so the build user must be able to write
# there. That is fine: those writes go to the container's own layer, which
# `docker run --rm` throws away after each crate, and never reach the image.
