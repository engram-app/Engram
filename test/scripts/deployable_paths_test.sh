#!/usr/bin/env bash
# test/scripts/deployable_paths_test.sh
#
# deployable_paths.sh must diff against the nearest ancestor that HAS an
# image, not HEAD~1. A deployable merge whose CI died before the build,
# followed by a CI-only merge, otherwise strands the deployable change.
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/../../scripts/deployable_paths.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Fake docker: `docker manifest inspect img:<sha7>` succeeds only for shas
# listed in $TMP/built.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'SH'
#!/usr/bin/env bash
tag="${3##*:}"
grep -qxF "$tag" "$BUILT_FILE"
SH
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH" BUILT_FILE="$TMP/built" DEPLOYABLE_PATHS="lib mix.exs"

repo="$TMP/repo"
git init -q "$repo"
cd "$repo"
git config user.email t@t
git config user.name t
commit() { mkdir -p "$(dirname "$1")"; echo "$RANDOM" >> "$1"; git add -A; git commit -qm "$1"; git rev-parse --short=7 HEAD; }

base=$(commit lib/a.ex)
echo "$base" > "$BUILT_FILE"
commit lib/b.ex >/dev/null               # deployable, CI died, never built
commit test/c_test.exs >/dev/null        # CI-only merge on top

# --- Test 1: stranded deployable change is reported ---
out=$(bash "$SCRIPT" img)
grep -qxF lib/b.ex <<<"$out" || fail "Test 1: stranded lib/b.ex not reported (got: $out)"
grep -qF test/c_test.exs <<<"$out" && fail "Test 1: non-deployable path reported"

# --- Test 2: parent has an image, CI-only merge → nothing deployable ---
git rev-parse --short=7 HEAD >> "$BUILT_FILE"
commit test/d_test.exs >/dev/null
out=$(bash "$SCRIPT" img)
[ -z "$out" ] || fail "Test 2: expected empty, got: $out"

# --- Test 3: no imaged ancestor in range → falls back to HEAD~1 ---
: > "$BUILT_FILE"
commit lib/e.ex >/dev/null
out=$(bash "$SCRIPT" img)
[ "$out" = "lib/e.ex" ] || fail "Test 3: expected lib/e.ex, got: $out"

echo "All tests passed (3)."
