#!/bin/bash
# Build and install the Rust transaction runtime bundled by the iOS app.

set -euo pipefail

MODE=${1:-release}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
APP_PACKAGE_DIR="$REPOSITORY_ROOT/KasSigner/Resources/Web/pkg"
BRIDGE_FILE="$REPOSITORY_ROOT/KasSigner/Resources/Web/bridge.html"
STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kassigner-runtime.XXXXXX")

cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

case "$MODE" in
    release)
        PROFILE_FLAG=--release
        ;;
    dev)
        PROFILE_FLAG=--dev
        ;;
    *)
        echo "Usage: $0 [release|dev]" >&2
        exit 2
        ;;
esac

echo "Building KasSigner transaction runtime ($MODE)..."

cd "$SCRIPT_DIR"
wasm-pack build \
    --target web \
    "$PROFILE_FLAG" \
    --out-dir "$STAGING_DIR/generated" \
    --out-name kassee_web \
    -- \
    --locked

# The Rust crate's historical package name is kassee_web. The iOS bridge loads
# this newer transaction build separately as kassee_tx, so adjust only the
# generated default WASM filename while staging the output.
sed "s/new URL('kassee_web_bg.wasm'/new URL('kassee_tx_bg.wasm'/" \
    "$STAGING_DIR/generated/kassee_web.js" \
    > "$STAGING_DIR/kassee_tx.js"
cp "$STAGING_DIR/generated/kassee_web_bg.wasm" \
    "$STAGING_DIR/kassee_tx_bg.wasm"

node --check "$STAGING_DIR/kassee_tx.js"

TRANSACTION_VERSION=$(shasum -a 256 "$STAGING_DIR/kassee_tx_bg.wasm" | awk '{print substr($1, 1, 16)}')
VERSION_LINE_COUNT=$(grep -Ec 'const transactionRuntimeVersion = "[0-9a-f]+";' "$BRIDGE_FILE")

if [ "$VERSION_LINE_COUNT" -ne 1 ]; then
    echo "Expected exactly one transactionRuntimeVersion in $BRIDGE_FILE" >&2
    exit 1
fi

sed -E \
    "s/const transactionRuntimeVersion = \"[0-9a-f]+\";/const transactionRuntimeVersion = \"$TRANSACTION_VERSION\";/" \
    "$BRIDGE_FILE" \
    > "$STAGING_DIR/bridge.html"

install -m 0644 "$STAGING_DIR/kassee_tx.js" \
    "$APP_PACKAGE_DIR/kassee_tx.js"
install -m 0644 "$STAGING_DIR/kassee_tx_bg.wasm" \
    "$APP_PACKAGE_DIR/kassee_tx_bg.wasm"
install -m 0644 "$STAGING_DIR/bridge.html" "$BRIDGE_FILE"

echo "Installed kassee_tx runtime version $TRANSACTION_VERSION into the iOS app."
