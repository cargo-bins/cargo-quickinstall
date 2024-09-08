FROM rust:1-buster as builder

WORKDIR /usr/src/app
COPY . .
# Will build and cache the binary and dependent crates in release mode
RUN --mount=type=cache,target=/usr/local/cargo,from=rust:latest,source=/usr/local/cargo \
    --mount=type=cache,target=target \
    cargo build --release && mv ./target/release/cargo-quickinstall-stats-server ./cargo-quickinstall-stats-server

# Runtime image
FROM debian:buster-slim

# Install libssl1.1 and ca-certificates
RUN apt-get update && apt-get install -y libssl1.1 ca-certificates && rm -rf /var/lib/apt/lists/*

# Run as "app" user
RUN useradd -ms /bin/bash app

USER app
WORKDIR /app

# Get compiled binaries from builder's cargo install directory
COPY --from=builder /usr/src/app/cargo-quickinstall-stats-server /app/cargo-quickinstall-stats-server

# Run the app
CMD ./cargo-quickinstall-stats-server
