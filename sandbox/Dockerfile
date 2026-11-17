# Image that build-crate.sh runs in for Linux targets, see build-version.sh.
#
# It is built in the same job, before any crate code runs, and never cached:
# a cached image could be poisoned by the build of one crate and then used to
# build the next.
FROM ubuntu:24.04@sha256:73b999393d07f2bf65a40373778a44dc9a6d54ad7718d29247d8ff9413c4d6a8

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
RUN url="https://static.rust-lang.org/rustup/dist/$(uname -m)-unknown-linux-gnu/rustup-init" \
    && curl --proto '=https' --tlsv1.2 -sSf -o /tmp/rustup-init "$url" \
    && echo "$(curl --proto '=https' --tlsv1.2 -sSf "$url.sha256" | cut -d' ' -f1)  /tmp/rustup-init" | sha256sum -c - \
    && chmod +x /tmp/rustup-init \
    && /tmp/rustup-init -y --profile minimal --default-toolchain stable --no-modify-path \
    && rm /tmp/rustup-init \
    && rustup target add \
        x86_64-unknown-linux-gnu x86_64-unknown-linux-musl \
        aarch64-unknown-linux-gnu aarch64-unknown-linux-musl \
        armv7-unknown-linux-gnueabihf armv7-unknown-linux-musleabihf \
    && chmod -R a+rX "$RUSTUP_HOME" "$CARGO_HOME"

COPY zigbuild-requirements.txt /opt/zigbuild-requirements.txt
RUN python3 -m venv /opt/zigbuild \
    && /opt/zigbuild/bin/pip install --no-cache-dir -r /opt/zigbuild-requirements.txt \
    && chmod -R a+rX /opt/zigbuild
