#!/usr/bin/env bash
# test/scripts/discord_release_notes_test.sh
#
# Tests scripts/discord_release_notes.sh — the release-notes → Discord
# announcement formatter. Pure stdin/stdout, no network, no `gh`.
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/../../scripts/discord_release_notes.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# A realistic engram release body: SCHEMA-IMPACT preamble (which is what
# the old `${NOTES:0:1600}` truncation used to emit *instead of* the
# actual changes), then the release-please sections.
ENGRAM_BODY='## SCHEMA-IMPACT

This release modifies the database schema. **Take a database backup before upgrading.**

### Upgrade procedure (self-host)

```bash
docker compose down
docker compose pull
docker compose up -d
```

### Schema-impacting PRs in this release

- #1280 (`phase/expand`) — feat: event-driven link-extract fast path
- #1229 (`phase/expand`) — feat: wikilink graph

### Rollback (optional)

```bash
bin/engram eval '"'"'Engram.Release.rollback(Engram.Repo, <previous-version>)'"'"'
```

---



### Features

* **editor:** Obsidian-style note header, inline title, and Properties block ([#1219](https://github.com/engram-app/Engram/issues/1219)) ([f7415ae](https://github.com/engram-app/Engram/commit/f7415aed60d4f81f304ab586cb4b60e0e2cd962f))
* event-driven link-extract fast path + bind-time rename repair ([#1280](https://github.com/engram-app/Engram/issues/1280)) ([b349787](https://github.com/engram-app/Engram/commit/b34978740b0ea1851c997e4319f2ad10a79243d5))

### Bug Fixes

* **crdt:** stop dropping inserts at the frontmatter boundary ([#396](https://github.com/engram-app/Engram/issues/396)) ([9d4f1e4](https://github.com/engram-app/Engram/commit/9d4f1e4a7b5fca404e7a15b4c22a5e69de0f2d56))
* **ci:** give prebuild-ci-image the MinIO vars compose parses ([#1277](https://github.com/engram-app/Engram/issues/1277)) ([eee5555](https://github.com/engram-app/Engram/commit/eee5555))
* **deps:** bandit 1.12.4 patches 3 WebSocket CVEs ([#1271](https://github.com/engram-app/Engram/issues/1271)) ([fff6666](https://github.com/engram-app/Engram/commit/fff6666))

### Miscellaneous Chores

* bump deps ([#1300](https://github.com/engram-app/Engram/issues/1300)) ([aaa1111](https://github.com/engram-app/Engram/commit/aaa1111))
* tidy the makefile ([#1301](https://github.com/engram-app/Engram/issues/1301)) ([bbb2222](https://github.com/engram-app/Engram/commit/bbb2222))

### Documentation

* route the headless-rAF doc ([#153](https://github.com/engram-app/Engram/issues/153)) ([ccc3333](https://github.com/engram-app/Engram/commit/ccc3333))'

URL='https://github.com/engram-app/Engram/releases/tag/release-v0.14.0'

# --- Test 1: user-facing sections survive; SCHEMA-IMPACT preamble does not ---
out=$(printf '%s' "$ENGRAM_BODY" | bash "$SCRIPT" "Engram Cloud" "release-v0.14.0" "$URL")

grep -q 'release-v0.14.0' <<<"$out"            || fail "Test 1: missing tag"
grep -q 'Obsidian-style note header' <<<"$out" || fail "Test 1: missing feature bullet"
grep -q 'link-extract fast path' <<<"$out"     || fail "Test 1: missing second feature bullet"
grep -q 'frontmatter boundary' <<<"$out"       || fail "Test 1: missing fix bullet"
grep -qF "$URL" <<<"$out"                       || fail "Test 1: missing full-notes link"

# The whole point: self-host upgrade choreography must NOT be the announcement.
grep -q 'docker compose down' <<<"$out" && fail "Test 1: leaked self-host upgrade steps" || true
grep -q 'Engram.Release.rollback' <<<"$out" && fail "Test 1: leaked rollback block" || true
grep -q 'Schema-impacting PRs' <<<"$out" && fail "Test 1: leaked schema PR list" || true

# --- Test 2: no upgrade warning is added, even for an old body that has the block ---
# Database changes need no operator step, so the announcement never says
# "back up before upgrading".
grep -qi 'schema' <<<"$out" && fail "Test 2: a schema/backup warning was added" || true
grep -qi 'back up' <<<"$out" && fail "Test 2: a backup warning was added" || true

# --- Test 3: markdown link noise stripped, PR ref kept ---
grep -q '(#1219)' <<<"$out" || fail "Test 3: PR number not preserved as plain ref"
grep -q 'https://github.com/engram-app/Engram/issues/' <<<"$out" && \
  fail "Test 3: raw issue URLs leaked into announcement" || true
grep -q 'commit/f7415ae' <<<"$out" && fail "Test 3: commit link leaked" || true

# --- Test 4: non-user-facing sections are counted, not listed ---
grep -q 'tidy the makefile' <<<"$out" && fail "Test 4: chore listed as a change" || true
grep -q 'route the headless-rAF doc' <<<"$out" && fail "Test 4: docs listed as a change" || true

# --- Test 4b: internal SCOPES are counted too, even inside Bug Fixes ---
# release-please files `fix(ci):` and `fix(deps):` under "Bug Fixes", but a
# CI plumbing fix is not an announcement. Filtering by section alone leaves
# the list dominated by ci/deps noise — the scope is the real signal.
grep -q 'prebuild-ci-image' <<<"$out" && fail "Test 4b: ci-scoped fix listed as a user-facing change" || true
grep -q 'bandit 1.12.4' <<<"$out"     && fail "Test 4b: deps-scoped fix listed as a user-facing change" || true
grep -q 'frontmatter boundary' <<<"$out" || fail "Test 4b: real user-facing fix was wrongly filtered"
# 2 chores/docs + 1 doc entry + 2 internal-scope fixes = 5 counted
grep -qE '5 (chore|other|internal)' <<<"$out" || fail "Test 4: expected a count of the 5 skipped entries"

# --- Test 5: plugin-shaped body (no schema impact, fixes only) ---
PLUGIN_BODY='## [1.20.1](https://github.com/engram-app/Engram-obsidian/compare/1.20.0...1.20.1) (2026-08-06)


### Bug Fixes

* **crdt:** stop dropping inserts at the frontmatter boundary ([#396](https://github.com/engram-app/Engram-obsidian/issues/396)) ([9d4f1e4](https://github.com/engram-app/Engram-obsidian/commit/9d4f1e4))
* **sync:** id-keyed move must not discard content over an EMPTY target ([#394](https://github.com/engram-app/Engram-obsidian/issues/394)) ([efee0b6](https://github.com/engram-app/Engram-obsidian/commit/efee0b6))'

out_plugin=$(printf '%s' "$PLUGIN_BODY" | bash "$SCRIPT" "Engram Vault Sync" "1.20.1" "https://example.test/r/1.20.1")

grep -q 'Engram Vault Sync' <<<"$out_plugin"   || fail "Test 5: missing product name"
grep -q 'id-keyed move' <<<"$out_plugin"       || fail "Test 5: missing fix bullet"
grep -qi 'schema' <<<"$out_plugin" && fail "Test 5: schema flagged on a release with no schema impact" || true

# --- Test 6: output always fits Discord's 2000-char content cap ---
# Build a body with far more bullets than could ever fit.
big_body=$'### Features\n'
for i in $(seq 1 200); do
  big_body+="* **scope${i}:** a reasonably wordy change description number ${i} that eats budget ([#${i}](https://x.test/i/${i})) ([abc${i}](https://x.test/c/abc${i}))"$'\n'
done
out_big=$(printf '%s' "$big_body" | bash "$SCRIPT" "Engram Cloud" "release-v9.9.9" "$URL")

len=${#out_big}
[ "$len" -le 2000 ] || fail "Test 6: output ${len} chars exceeds Discord's 2000 cap"
# Truncation must drop whole bullets and still land the link — never cut mid-URL.
grep -qF "$URL" <<<"$out_big" || fail "Test 6: full-notes link lost to truncation"
grep -qE '…and [0-9]+ more' <<<"$out_big" || fail "Test 6: no indication that changes were omitted"

# --- Test 7: empty / unparseable body still produces a valid announcement ---
out_empty=$(printf '%s' "" | bash "$SCRIPT" "Engram Cloud" "release-v0.0.1" "$URL")
[ -n "$out_empty" ] || fail "Test 7: empty output on empty notes"
grep -q 'release-v0.0.1' <<<"$out_empty" || fail "Test 7: missing tag on empty notes"
grep -qF "$URL" <<<"$out_empty"           || fail "Test 7: missing link on empty notes"

# --- Test 8: no unescaped backticks/quotes break the JSON the caller builds ---
TRICKY='### Bug Fixes

* handle a `"quoted"` path with \ backslash ([#1](https://x.test/i/1)) ([d1](https://x.test/c/d1))'
out_tricky=$(printf '%s' "$TRICKY" | bash "$SCRIPT" "Engram Cloud" "v1" "$URL")
# jq must be able to encode it — this is exactly what the action does.
printf '%s' "$out_tricky" | jq -Rs '{content:.}' >/dev/null || fail "Test 8: output not JSON-encodable"

echo "All tests passed (8)."
