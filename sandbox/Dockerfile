# Image that build-crate.sh runs in for Linux targets, see build-version.sh.
#
# It is built in the same job, before any crate code runs, and never cached:
# a cached image could be poisoned by the build of one crate and then used to
# build the next.
#
# The base is an Ubuntu LTS. .github/dependabot.yml ignores the interim
# releases, so Dependabot moves it from one LTS to the next. Without that it
# would propose releases such as 25.10, and its cooldown even favours the
# end-of-life ones, since those tags are no longer rebuilt.
FROM ubuntu:26.04@sha256:d66b366dac61b575bee2aef07e9c26e8070096fbe84a3d4d3eb0da069b5d76db

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
