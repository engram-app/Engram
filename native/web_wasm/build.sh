#!/usr/bin/env bash
# Builds frontend/src/crdt/frontmatter-fence.wasm from native/web_wasm. The
# .wasm is COMMITTED (the frontend builds with bun only); CI reruns this and
# fails if the committed bytes differ. Paths are remapped and the profile
# strips everything, so the bytes do not depend on the checkout or cargo home.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$(pwd)
target="${CARGO_TARGET_DIR:-$root/target}"
export RUSTFLAGS="-C link-arg=-zstack-size=16384 --remap-path-prefix=$root=. --remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=cargo"
cargo build --locked --profile wasm -p web_wasm --target wasm32-unknown-unknown
out="$root/../frontend/src/crdt/frontmatter-fence.wasm"
cp "$target/wasm32-unknown-unknown/wasm/web_wasm.wasm" "$out"
echo "frontmatter-fence.wasm: $(wc -c <"$out") bytes, $(gzip -9c "$out" | wc -c) gzipped"
