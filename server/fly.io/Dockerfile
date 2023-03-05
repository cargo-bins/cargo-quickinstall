FROM rust:latest as builder

# Make a fake Rust app to keep a cached layer of compiled crates
RUN USER=root cargo new app
WORKDIR /usr/src/app
COPY Cargo.toml Cargo.lock ./
# Needs at least a main.rs file with a main function
RUN mkdir src && echo "fn main(){}" > src/main.rs
# Will build all dependent crates in release mode
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/src/app/target \
    cargo build --release

# Copy the rest
COPY . .
# Build (install) the actual binaries
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/src/app/target \
    cargo install --path .

# Runtime image
FROM debian:bullseye-slim

# Run as "app" user
RUN useradd -ms /bin/bash app

USER app
WORKDIR /app

# Debian slim doesn't have ca certs and I can't be bothered asking apt for them.
copy --from=rust:latest /etc/ssl/certs /etc/ssl/certs

# Get compiled binaries from builder's cargo install directory
COPY --from=builder /usr/local/cargo/bin/cargo-quickinstall-stats-server /app/cargo-quickinstall-stats-server

# No CMD or ENTRYPOINT, see fly.toml with `cmd` override.
