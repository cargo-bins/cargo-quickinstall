# Hello Rust!

This is an example app demonstrating how to deploy a Rust program on Fly.io

## Structure

### App

Warp-based "hello world" app, as simple as it can get.

#### Binding to all addresses

Noticed this line?

```rust
    warp::serve(routes)
        // ipv6 + ipv6 any addr
        .run(([0, 0, 0, 0, 0, 0, 0, 0], 8080))
        .await;
```

This listens to all addresses on both IPv4 and IPv6, on port 8080. It's important to do this because your app would otherwise need to know about the `172.19.0.0/16` IP it should bind to specifically. Binding to IPv6 is not required, but is likely a good idea going forward.

### fly.toml

A fairly standard `fly.toml` configuration, except for the `cmd` override:

```toml
[experimental]
cmd = "./hello" # should be the name of the binary you want to run
```

### Dockerfile

The most efficient way to create a Docker image for a Rust app is a simple Dockerfile.

Our `Dockerfile` is heavily commented, but here's a short rundown:
- Copy `Cargo.{toml,lock}` and build dependencies
- Copy whole project and `cargo install` it
- 

#### .dockerignore

You definitely want to ignore `/target` since this can get pretty hefty, adding to the build context's size, and slow down builds significantly.

## Deploy

```
fly launch
```

