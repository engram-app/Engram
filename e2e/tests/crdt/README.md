# CRDT file-level sync e2e

Exercises the behaviours that are **unique to the CRDT sync path** (spec §12a)
plus the regressions that broke it. These are the tests that would have caught
the device-B "content stuck in the Yjs doc, never written to disk" bug.

## What's covered

| Test | Property (legacy sync cannot do these) |
|------|----------------------------------------|
| `test_discovery_creates_file_on_b` | A creates a note B never had → file **created on B's disk** (regression guard for `flushFromCrdt`) |
| `test_concurrent_edits_both_survive` | A and B edit the same note independently → **both edits survive** (true CRDT merge; last-write-wins would drop one) |
| `test_no_conflict_modal_on_divergence` | A divergence that would pop the legacy ConflictModal **merges silently** |
| `test_content_reaches_rest_after_checkpoint` | CRDT body lands in REST `notes.content` after the checkpoint (eventual consistency) |
| `test_delete_propagates` | delete on A removes the file on B |
| `test_edit_after_discovery_round_trips` | a note B discovered is fully CRDT-managed — B's edit flows back to A |

## CRDT-aware assertions

Unlike the legacy REST path, a CRDT note is **eventually consistent**: the body
is delivered device→device over the y-protocols handshake and only flushed to
`notes.content` on the debounced checkpoint (~5s). So these tests poll the
**vault file on disk** (`helpers.vault.wait_for_content`) and REST content with
generous timeouts — **never an immediate read-after-write**. Asserting immediate
REST consistency (the legacy suite's pattern) fails under CRDT by design, which
is why the legacy tests must NOT run with CRDT enabled.

## Running locally

Requires the CI stack (backend CRDT is unconditional — the old
`CRDT_ENABLED` stack flag was dead config) and the plugin opted in via
`E2E_ENABLE_CRDT=true`:

```bash
# Bring up the local-auth stack (the crdt: channel is always advertised)
docker compose -f ci/compose.yml -f ci/compose.local.yml -p engram-crdt up -d --build --wait

cd e2e
E2E_ENABLE_CRDT=true \
ENGRAM_API_URL=http://localhost:8100/api \
CI_POSTGRES_CONTAINER=engram-crdt-postgres-1 \
CI_MINIO_CONTAINER=engram-crdt-minio-1 \
python3 -m pytest tests/crdt/ -v
```

The suite **skips entirely** unless `E2E_ENABLE_CRDT=true` (a `pytestmark`
skipif), so it is a no-op in the legacy e2e jobs.

## CI

`tests/crdt/` runs in the `e2e-crdt` job in `.github/workflows/verify.yml`
(`AUTH_PROVIDER=local` + `E2E_ENABLE_CRDT=true`), which also runs
`tests/api_only/` on the same local-auth stack (absorbed from the old
`e2e-local` job).
