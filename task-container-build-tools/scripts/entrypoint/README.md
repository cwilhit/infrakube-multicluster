# entrypoint

This binary sets up the infrakube task pod. Written in Rust, compiled as a static musl binary.

## Build

### Using Docker (multi-arch)

```bash
./build.sh
```

This produces `bin/entrypoint-amd64` and `bin/entrypoint-arm64`.

### Local build

```bash
cargo build --release
```

The binary is at `target/release/entrypoint`.

## Contribution

Issues, comments, and pull requests are welcomed.