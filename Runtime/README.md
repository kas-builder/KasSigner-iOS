# KasSigner WebAssembly runtime

The iOS app ships its JavaScript and WebAssembly files in
`KasSigner/Resources/Web/pkg` so cloning and building the Xcode project does not
require a Rust toolchain.

The bridge currently loads two bundles:

- `kassee_web` is the primary wallet and synchronization runtime.
- `kassee_tx` is the newer transaction-building runtime produced from the Rust
  crate in `Runtime/kassee`.

## Rebuilding `kassee_tx`

Install the development prerequisites once:

```bash
rustup target add wasm32-unknown-unknown
cargo install wasm-pack
```

From the repository root, run:

```bash
Runtime/kassee/build.sh
```

The script builds with `Cargo.lock`, validates the generated JavaScript, stages
all output before installation, copies only the two required `kassee_tx` files
into the app, and updates the transaction-runtime cache version in
`bridge.html`. Use `Runtime/kassee/build.sh dev` only for local debug builds.

Commit the Rust source, generated `kassee_tx` files, and matching
`bridge.html` cache-version change together.
