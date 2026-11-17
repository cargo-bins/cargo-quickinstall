# Image that build-crate.sh runs in for Linux targets, see build-version.sh.
#
# It is built in the same job, before any crate code runs, and never cached:
# a cached image could be poisoned by the build of one crate and then used to
# build the next.
FROM ubuntu:25.10@sha256:7cc5e35f6567ee8c66d2abb4aab0fd866669e6207c237c3a8f0947a5c7f17092

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
COPY supported-targets /opt/supported-targets
RUN url="https://static.rust-lang.org/rustup/dist/$(uname -m)-unknown-linux-gnu/rustup-init" \
    && curl --proto '=https' --tlsv1.2 -sSf -o /tmp/rustup-init "$url" \
    && echo "$(curl --proto '=https' --tlsv1.2 -sSf "$url.sha256" | cut -d' ' -f1)  /tmp/rustup-init" | sha256sum -c - \
    && chmod +x /tmp/rustup-init \
    && /tmp/rustup-init -y --profile minimal --default-toolchain stable --no-modify-path \
    && rm /tmp/rustup-init \
    && rustup target add $(tr -s ' ' '\n' < /opt/supported-targets | grep -- '-linux-') \
    && chmod -R a+rX "$RUSTUP_HOME" "$CARGO_HOME"

COPY zigbuild-requirements.txt /opt/zigbuild-requirements.txt
RUN python3 -m venv /opt/zigbuild \
    && /opt/zigbuild/bin/pip install --no-cache-dir -r /opt/zigbuild-requirements.txt \
    && chmod -R a+rwX /opt/zigbuild
# cargo-zigbuild patches zig's libc headers for some targets (such as
# arm-features.h for armv7 glibc), so the build user must be able to write
# there. That is fine: the image is built for one crate and then thrown away.
