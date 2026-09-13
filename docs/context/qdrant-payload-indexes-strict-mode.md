# Context Doc: Qdrant payload indexes under strict mode

_Last verified: 2026-09-11_

## Status
Fixed (#1609). `ensure_collection/2` now reconciles missing payload indexes on every boot.

## Symptom
- Folder, tag, OKF `type` and date filters return a 400 from Qdrant Cloud.
- REST `/api/search` surfaces `{"error": "search_failed"}`; MCP `search_notes` says "Search unavailable."
- Unfiltered search works, so it looks intermittent or filter-specific.
- Staging (self-hosted Qdrant) does not enforce strict mode, so e2e cannot catch it. Only Qdrant Cloud (prod) does.

## Verified on prod (2026-09-11)
Qdrant 1.18.2, collection `engram_notes`:
- `strict_mode_config.enabled=true`, `unindexed_filtering_retrieve=false`: a filter on an un-indexed field is rejected, not slow.
- `payload_schema` held only `user_id, vault_id, note_id, path_hmac`.

## Root Cause
Until #1609, payload indexes were created only right after a FRESH collection create (the `{:ok, :created}` branch). Any field added to `@payload_index_fields` later (`type_hmac`, `fm_timestamp`, `fm_created`) never reached an already-existing collection. `folder_hmac` and `tags_hmac` were filtered on but never listed at all.

## Fix (#1609)
`do_ensure_collection/2` calls `ensure_payload_indexes/2` on both branches. On a 409 (exists), `verify_collection_shape/1` already GETs `collection_info`; it now also returns the `payload_schema` keys, and only the missing fields get a `PUT /collections/<col>/index?wait=true`. A fully indexed collection costs no extra requests. The whole call is memoised per node in `:persistent_term` (#1501), so this runs once per boot.

## Rule going forward
Any new filter key MUST be added to `@payload_index_fields` (keyword: equality/any-match) or `@integer_payload_index_fields` (range). It then self-heals on the next deploy. A filter key missing from both lists works on staging and 400s on prod.

## Checking prod (read-only)
1. Capture the key into a shell variable, never echo it: `KEY=$(./bin/sops-get prod qdrant_api_key --show)`. The script lives in the engram-infra repo (`bin/sops-get`), so run it from there.
2. `GET <QDRANT_URL>/collections/engram_notes` with header `api-key: $KEY`.
3. Read `.result.payload_schema` (which fields are indexed) and `.result.config.strict_mode_config`.

## Gotchas
- **Known ceiling (the `ponytail:` comment in `ensure_payload_indexes/2`):** if `collection_info` is unreadable at boot, `verify_collection_shape/1` returns `:unknown`, the index check is skipped, and the memo holds `:ok` until the node restarts. Another node or the next boot reconciles.
- A collection dropped or recreated out of band needs `forget_collection_memo/0`, or the node keeps skipping `ensure_collection`.
- Staging green says nothing about filters. Check prod `payload_schema` when a filter-only search fails.

## File Anchors
- `lib/engram/vector/qdrant.ex`: `@payload_index_fields`, `@integer_payload_index_fields`, `ensure_collection/2`, `ensure_payload_indexes/2`, `verify_collection_shape/1`
- `test/engram/vector/qdrant_collection_test.exs`
- `lib/engram_web/controllers/search_controller.ex` (`search_failed`), `lib/engram/mcp/handlers.ex` (`render_search/2`)

## References
- Issue #1609 (this fix), #626 (original index list), #1501 (per-node memo)
