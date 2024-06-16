ARG ZIG_VERSION=0.13.0

FROM rust:slim

RUN apt-get update && \
    apt-get install -y curl wget && \
    wget -O - https://apt.llvm.org/llvm.sh | sudo bash && \
    rm -rf /var/cache/apt/archives /var/lib/apt/lists/* && \
    curl -L https://ziglang.org/download/0.13.0/zig-linux-x86_64-$ZIG_VERSION.tar.xz | tar xf && \
    curl -L --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh | bash && \
    cargo binstall -y cargo-auditable cargo-zigbuild

ENV PATH="${PATH}:$HOME/zig-linux-x86_64-$ZIG_VERSION"

ADD pkg-config-cross.sh build-linux-version.sh .
