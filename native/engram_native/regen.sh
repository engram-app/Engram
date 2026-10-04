#!/usr/bin/env bash
# Regenerate src/snowball/algorithms/*.rs from the Snowball sources that the
# Elixir stemmer (text_stemmer) shipped, so stems stay identical to what the
# keyword index was built with. The Snowball runtime (among.rs,
# snowball_env.rs) is vendored from the same checkout; see COPYING (BSD-3).
#
#   SBL_DIR=path/to/algorithms ./regen.sh
set -euo pipefail
cd "$(dirname "$0")"
SBL_DIR=${SBL_DIR:?point SBL_DIR at a directory of .sbl files}
work=$(mktemp -d)
git clone -q --depth 1 https://github.com/snowballstem/snowball.git "$work/snowball"
make -C "$work/snowball" snowball >/dev/null
for f in "$SBL_DIR"/*.sbl; do
  n=$(basename "$f" .sbl)
  "$work/snowball/snowball" "$f" -rust -o "src/snowball/algorithms/${n}_stemmer"
done
sed -i 's/^use snowball::/use crate::snowball::/' src/snowball/algorithms/*.rs
(cd src/snowball/algorithms && for f in *_stemmer.rs; do echo "pub mod ${f%.rs};"; done > mod.rs)
rm -rf "$work"
