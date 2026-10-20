# Attachments: sync everything + large files (backend + web) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The server accepts every non-executable attachment within plan limits, and files up to the plan's `max_file_bytes` (200/500 MiB) upload in resumable parts and download in streamed segments, with no plaintext at rest.

**Architecture:** `MimeWhitelist` shrinks to an executable-extension blocklist. A new parts protocol (`/api/attachment-uploads/*`) stores state in a tenant table, encrypts each part as one AES-GCM segment under a per-file key (wrapped by the user's DEK), and writes it as one S3 multipart part. Rows gain `encryption_version: 2`; v1 rows and the single-request path are unchanged.

**Tech Stack:** Elixir 1.17 / Phoenix 1.8, Ecto + Postgres RLS, ExAws S3 multipart, Oban cron, Rust NIF envelope (`Engram.Native`), React + vitest (web app).

**Spec:** Engram vault `50 Engineering/_Superpowers Specs/2026-10-19-attachments-sync-everything-design.md` (approved 2026-10-19). Companion plugin plan: `engram-obsidian-sync/docs/superpowers/plans/2026-10-19-attachments-sync-everything.md`.

## Global Constraints

- Prerequisite: Engram#2054 (refusal telemetry; adds `EngramWeb.AttachmentRawResponse`) merged; rebase this branch on it.
- Upgrades need zero operator action; skip-release safe. Migrations additive only, no backfill, apply on boot.
- New tenant table: `ENABLE` + `FORCE ROW LEVEL SECURITY`, `tenant_isolation_<t>` policy, `maintenance_all` policy `TO engram_maintenance`, `GRANT ... TO engram_app`, and add to `@tenant_tables` in `lib/engram/repo.ex:18`. Template: `priv/repo/migrations/20261006120000_create_note_revisions_expand.exs`.
- Per-request body stays under `EngramWeb.Endpoint.max_body_bytes()` (11_000_000). Part size: `8 * 1024 * 1024` (8 MiB, ≥ S3's 5 MiB minimum).
- No plaintext attachment bytes in S3, ever. Serving stays force-download unless `inline_safe?/1`.
- Self-host `Engram.Storage.Database` raises on multipart: it must not advertise the parts protocol.
- No version bumps (release-please). Conventional commits, signed. `mise exec --` for mix and git push. Format + credo --strict + dialyzer before push. Targeted tests locally only; full suite on CI.
- User-facing copy: no em dashes; new strings through translategemma (`make i18n-core-sync` / repo i18n pipeline), never hand-translated.
- Regenerate `openapi.json` after any spec change: `mix openapi.spec.json --spec EngramWeb.ApiSpec --pretty=true openapi.json`.

## Review Focus

1. **Same-path race across protocols:** a v1 single-request upload and a v2 parts upload complete on one path at once. Expected: one live row, the other's blob deleted, the winner's wrapped key bound to the winning id. Test in Task 5.
2. **Resume after every failure point:** a part PUT that dies after S3 accepted it but before the DB recorded the ETag. Expected: re-PUT of part n replaces it; `complete` succeeds. Test in Task 5.
3. **Declared size lies:** client declares 10 MiB then sends 12 parts, or a short last part, or a part over `part_size`. Expected: 422, nothing stored, no quota consumed. Test in Task 5.
4. **Quota race:** two parts uploads that each fit the quota but not together. Expected: the second `complete` is refused 402 and its blob aborted. Test in Task 5.
5. **Header injection survives the allowlist removal:** a `mime_type` with `\r\n` or `\0`. Expected: 422 at upload, never stored (else `?raw=1` 500s forever on that row). Test in Task 1.

---

### Task 1: Executable blocklist replaces the MIME allowlist

**Files:**
- Modify: `lib/engram/storage/mime_whitelist.ex` (keep module name; rename is churn)
- Modify: `lib/engram/attachments.ex:59`, `lib/engram_web/controllers/attachments_controller.ex:100-130` (415 branch), `config/runtime.exs:527-538`
- Modify: `lib/engram_web/schemas/attachments.ex:178` (`MimeRejected` → only `extension_not_allowed`), controller `operation(:upload)` description
- Modify: `lib/engram/mcp/handlers.ex:675-718` prose ("whitelisted binary types" → "any file type except executables")
- Modify: `docs/context/attachment-mime-whitelist.md`, `docs/context/environment-variables.md:192`
- Test: `test/engram/storage/mime_whitelist_test.exs`, `test/engram/attachments_test.exs:52,64`, `test/engram_web/controllers/attachments_controller_test.exs:106,123,137,461`, `e2e/tests/api_only/test_70_attachment_mime_whitelist.py`

**Interfaces:**
- Produces: `MimeWhitelist.check(mime :: String.t() | nil, filename :: String.t() | nil) :: :ok | {:error, {:extension_not_allowed, String.t()}} | {:error, :invalid_mime}`; `MimeWhitelist.blocked_extensions() :: [String.t()]` (sorted, lowercase, with leading dot).

- [ ] **Step 1: Write failing tests** in `mime_whitelist_test.exs`:
  - `check("application/zip", "a.zip") == :ok`; same for `application/epub+zip`/`a.epub`, `application/xml`/`a.xml`, `font/ttf`/`a.ttf`, `application/octet-stream`/`a.bin`, `nil`/`a.unknownext`.
  - `check("text/plain", "run.EXE") == {:error, {:extension_not_allowed, ".exe"}}` (case-insensitive, last extension); `check("image/png", "x.png.sh")` → `".sh"`; `check("image/png", "setup.msix")` and `".appimage"` refused.
  - `check("text/plain\r\nx: y", "a.txt") == {:error, :invalid_mime}`; same for `\0`.
  - `"text/plain" not in` and `".exe" in blocked_extensions()`.
- [ ] **Step 2: Run** `MIX_TEST_PARTITION=_att MIX_ENV=test mise exec -- mix test test/engram/storage/mime_whitelist_test.exs` → FAIL (zip refused today).
- [ ] **Step 3: Implement.** Drop `@mime_prefixes`, `@mime_explicit`, `extra_allowlist/0`, `mime_allowed?/1`. Keep `normalize/1`, `detect_mime/1`, `bypass?/0` (bypass also skips the blocklist). Add `.msix .msixbundle .appx .appxbundle .appimage .run .xpi .crx` to `@blocked_extensions` (review: double-click executables only; never `.js`/`.py`). Header-injection check moves to `check/2` as `{:error, :invalid_mime}`.
- [ ] **Step 4: Map `:invalid_mime` → 422 `{"error":"invalid_mime_type"}`** in both controller 415 sites and the `do_upload` context-error clause; drop the `mime_not_allowed` clauses. Remove `attachment_mime_allowlist_extra` from `config/runtime.exs` and both docs.
- [ ] **Step 5: Update the listed tests** to the new rule (zip/epub now 200; `.exe` still 415 `extension_not_allowed`), the e2e `test_70` the same way, MCP prose, OpenAPI; regenerate `openapi.json`.
- [ ] **Step 6: Run** the five test files above + `test/lint/` → PASS.
- [ ] **Step 7: Commit** `fix: accept every non-executable attachment`.

### Task 2: Advertise the rules and the parts protocol

**Files:**
- Modify: `lib/engram/storage.ex` (add `@callback multipart?() :: boolean()`), `lib/engram/storage/s3.ex` (true), `lib/engram/storage/database.ex` (false), `test/support/storage_in_memory.ex` (true; also enforce the 5 MiB minimum for non-final parts so tests catch it)
- Modify: `lib/engram_web/channels/user_channel.ex:38,54`, `lib/engram/billing.ex` `plan_state/1`
- Test: `test/engram_web/channels/user_channel_test.exs`, `test/engram/billing_test.exs`

**Interfaces:**
- Produces: join reply `features.chunked_attachment_upload :: boolean`, `features.attachment_part_size :: integer` (present only when true); `plan_state/1` adds `blocked_extensions :: [String.t()]`. Creates `lib/engram/attachments/uploads.ex` with only `Uploads.part_size/0 :: 8_388_608`; Task 4 fills in the rest.

- [ ] **Step 1: Failing tests:** join reply with S3/InMemory adapter has `chunked_attachment_upload: true, attachment_part_size: 8_388_608`; with `Engram.Storage.Database` swapped in (async: false) has `chunked_attachment_upload: false` and no `attachment_part_size`; `plan_state(user).blocked_extensions` contains `".exe"`. InMemory: `upload_part` of a 1-byte non-final part then `complete` returns `{:error, :entity_too_small}`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** `features/0` as a function (not `@features`) reading `Storage.adapter().multipart?()`.
- [ ] **Step 4: Run** → PASS. **Step 5: Commit** `feat: advertise chunked uploads and blocked types`.

### Task 3: Segmented per-file-key cipher (format v2)

**Files:**
- Create: `lib/engram/attachments/segmented_cipher.ex`
- Create: `priv/repo/migrations/20261020120000_add_segmented_attachment_columns_expand.exs`
- Modify: `lib/engram/attachments/attachment.ex` (fields + changeset), `lib/engram/crypto/envelope.ex:133-145` only if a new AAD prefix needs a policy entry
- Test: `test/engram/attachments/segmented_cipher_test.exs`, `test/engram/attachments/attachment_test.exs`

**Interfaces:**
- Produces:
  - `SegmentedCipher.new_file_key() :: <<_::256>>`
  - `SegmentedCipher.wrap_key(file_key, dek, att_id :: Ecto.UUID.t()) :: {wrapped :: binary, nonce :: binary}` (AAD `Crypto.aad_for_row(:attachments, :file_key, att_id)`)
  - `SegmentedCipher.unwrap_key(wrapped, nonce, dek, att_id) :: {:ok, <<_::256>>} | :error`
  - `SegmentedCipher.seal_segment(plaintext, file_key, upload_id :: Ecto.UUID.t(), index :: non_neg_integer, count :: pos_integer) :: binary` returning `nonce || ciphertext || tag`
  - `SegmentedCipher.open_segment(sealed, file_key, upload_id, index, count) :: {:ok, binary} | :error`
  - Attachment fields: `wrapped_file_key :: binary`, `file_key_nonce :: binary`, `upload_id :: Ecto.UUID`, `segment_size :: integer`, `segment_count :: integer`; `encryption_version in [1, 2]`; v2 requires the five fields and not `content_nonce`.

- [ ] **Step 1: Failing tests:** round-trip one segment; `open_segment` with a different `index`, `count`, `upload_id` or key returns `:error`; the final-flag (`index == count - 1`) is in the AAD, so a non-final segment opened as final fails (truncation); `unwrap_key` under a different `att_id` fails; v2 changeset valid with the five fields and no `content_nonce`, invalid if any is missing; v1 changeset unchanged.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** with `Envelope.encrypt/3` / `decrypt/4` (NIF, dirty-scheduled). Segment AAD: `aad_prefix(:attachments, :segment) <> upload_id_bytes <> <<index::32, count::32, final::8>>`. Segments are NOT compressed: keep `attachments:segment` out of `@policy` (or `:none`), since part sizes must stay exact. Migration adds nullable columns only.
- [ ] **Step 4: Run** → PASS. **Step 5: Commit** `feat: segmented per-file-key attachment cipher`.

### Task 4: Uploads table + context

**Files:**
- Create: `priv/repo/migrations/20261020120100_create_attachment_uploads_expand.exs`, `lib/engram/attachments/upload.ex` (schema), `lib/engram/attachments/uploads.ex` (context)
- Modify: `lib/engram/repo.ex:18` (`@tenant_tables`), `lib/engram/attachments.ex` (extract the locked row write from `upsert_attachment/3` into `commit_row/…` reused by v1 and v2; behaviour unchanged)
- Test: `test/engram/attachments/uploads_test.exs`

**Interfaces:**
- Consumes: `SegmentedCipher.*` (Task 3), `MimeWhitelist.check/2` (Task 1), `Storage.start_multipart/upload_part/complete_multipart_upload/abort_multipart_upload`.
- Produces (all scoped by `user`, `vault`):
  - `Uploads.part_size() :: 8_388_608`
  - `Uploads.start(user, vault, %{path, size_bytes, mtime, mime_type?}) :: {:ok, %Upload{id, part_size, part_count}} | {:error, {:extension_not_allowed, ext} | :invalid_mime | {:too_large, limit} | {:storage_cap_reached, used, cap} | :multipart_unsupported | Ecto.Changeset.t()}`
  - `Uploads.put_part(user, vault, upload_id, n :: pos_integer, bytes) :: {:ok, %{part: n}} | {:error, :not_found | :bad_part_number | :bad_part_size | {:storage, term}}`
  - `Uploads.status(user, vault, upload_id) :: {:ok, %{done: [pos_integer], part_count, part_size}} | {:error, :not_found}`
  - `Uploads.complete(user, vault, upload_id) :: {:ok, %Attachment{}} | {:error, :not_found | {:missing_parts, [pos_integer]} | {:storage_cap_reached, used, cap} | {:storage, term}}`
  - `Uploads.abort(user, vault, upload_id) :: :ok`
- Table `attachment_uploads`: `id`, `user_id`, `vault_id`, `attachment_id` (claimed at start), `path_hmac`, `path_ciphertext`, `path_nonce`, `mime_type`, `size_bytes`, `mtime`, `part_size`, `part_count`, `storage_key`, `s3_upload_id`, `wrapped_file_key`, `file_key_nonce`, `parts` (jsonb map n → etag), `inserted_at`, `updated_at`.

- [ ] **Step 1: Failing tests:** `start` on `a.exe` → `{:error, {:extension_not_allowed, ".exe"}}`; declared size over `max_file_bytes` → `{:too_large, _}`; over quota → `{:storage_cap_reached, _, _}`; with `Storage.Database` → `:multipart_unsupported`; happy path 20 MiB (3 parts) then `complete` → live attachment, `encryption_version: 2`, `content_hash` equals `Crypto.hmac_content_hash(key, full_plaintext)`, and opening each stored segment with `SegmentedCipher.open_segment/5` reproduces the bytes; part 2 sent twice succeeds; part of wrong size → `:bad_part_size`; `complete` with part 3 missing → `{:missing_parts, [3]}`; RLS control test: another user's `status` → `:not_found` (see `docs/context/rls-enforcement-testing-traps.md`, include a zero-rows control).
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.** Content HMAC (deviation from the spec's "incremental across parts": parts arrive out of order and can repeat, so a running MAC is wrong): after the S3 multipart completes, `complete` reads the object back segment by segment with a new `Storage.get_range(key, offset, length) :: {:ok, binary} | {:error, term}` callback (S3 `get_object` with `range:`; InMemory `binary_part`; Database not needed), opens each segment and feeds `:crypto.mac_init/update/final` with `dek_content_hash_key/1`. Memory stays one segment. Claim `attachment_id` at `start`: reuse the live row's id for the path if one exists, else a fresh UUID. `complete` takes the same advisory lock, re-checks quota against live usage, and if a different live row now holds the path (v1 race) rewraps the file key under that row's id (`wrap_key/3`) instead of re-encrypting; old blob deleted after commit.
- [ ] **Step 4: Run** → PASS. **Step 5: Commit** `feat: resumable attachment upload sessions`.

### Task 5: Upload endpoints

**Files:**
- Create: `lib/engram_web/controllers/attachment_uploads_controller.ex`
- Modify: `lib/engram_web/router.ex:680-686` (same vault-scoped scope), refusal telemetry plug from Engram#2054 applied to these actions too
- Test: `test/engram_web/controllers/attachment_uploads_controller_test.exs`

**Interfaces:**
- Consumes: `Uploads.*` (Task 4).
- Produces routes: `POST /api/attachment-uploads` → 201 `{upload_id, part_size, part_count}`; `PUT /api/attachment-uploads/:id/parts/:n` (octet-stream, body read with the same bounded `read_body` + 408/413 handling as `upload_raw/4`) → 200 `{part}`; `GET /api/attachment-uploads/:id` → 200 `{done, part_count, part_size}`; `POST /api/attachment-uploads/:id/complete` → 200 same body as `POST /api/attachments`; `DELETE /api/attachment-uploads/:id` → 204. Refusal bodies reuse `LimitResponse` (402 `file_too_large` / `attachments_quota_exceeded`) and 415 `extension_not_allowed`. `:multipart_unsupported` → 501.

- [ ] **Step 1: Failing tests** for each route's happy path and each Review Focus item 1-4:
  - race: v1 `POST /api/attachments` lands between `start` and `complete` on the same path → after `complete` exactly one live row for the path (query by `path_hmac`), `GET ?raw=1` returns the v2 bytes, the v1 blob key no longer exists in InMemory.
  - resume: PUT part 2, delete its entry from `parts` jsonb directly (simulate lost ETag), PUT part 2 again, `complete` → 200.
  - lies: declared 10 MiB, PUT part 3 → 422 `bad_part_number`; short non-final part → 422 `bad_part_size`; `usage` unchanged.
  - quota: two sessions each 60% of cap → first `complete` 200, second 402 `attachments_quota_exceeded`, second blob gone.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS + regenerate `openapi.json`.
- [ ] **Step 5: Commit** `feat: chunked attachment upload endpoints`.

### Task 6: Read, stream and rotate v2

**Files:**
- Modify: `lib/engram/attachments.ex` (`get_attachment/3` v2 branch returns a lazy segment stream; `decrypt/3` unchanged for v1), `lib/engram_web/attachment_raw_response.ex` (v2: `send_chunked` over the stream; `Range: bytes=` aligned to whole segments → 206), `lib/engram/crypto/user_dek_rotation.ex:558` (`recrypt_blob/5` v2 branch: rewrap file key only; no blob GET/PUT), JSON (non-raw) show for v2 → 413-free path: refuse with 409 `{"error":"use_raw_download"}` above the single-request ceiling
- Test: `test/engram_web/controllers/attachments_controller_test.exs`, `test/engram/crypto/user_dek_rotation_test.exs`

**Interfaces:**
- Consumes: `SegmentedCipher.open_segment/5`, `unwrap_key/4`, `Storage.get_range/3` (Task 4).
- Produces: `Attachments.get_attachment/3` returns `{:ok, %Attachment{content: binary}}` for v1 and `{:ok, %Attachment{content: {:segments, Enumerable.t()}}}` for v2.

- [ ] **Step 1: Failing tests:** v2 `?raw=1` body equals uploaded bytes, response is chunked, `x-engram-content-hash` present; `Range: bytes=8388608-` returns 206 with segment 2 onward; a tampered stored segment → connection closed after headers and an error log (not a 200 with garbage); DEK rotation over a v2 row changes only `wrapped_file_key`/`file_key_nonce`/`dek_version`, InMemory blob bytes unchanged, download still works.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat: stream and rotate segmented attachments`.

### Task 7: Expire abandoned uploads

**Files:**
- Create: `lib/engram/workers/attachment_upload_expiry.ex` (pattern: `lib/engram/workers/export_expiry_sweep.ex`; `queue: :maintenance`, finite `timeout/1`, `Repo.maintenance()` + `Repo.cross_tenant/1`)
- Modify: `config/config.exs:182-250` crontab (unique minute; `test/engram/oban_cron_test.exs` enforces it)
- Test: `test/engram/workers/attachment_upload_expiry_test.exs`

- [ ] **Step 1: Failing test:** a session with `updated_at` 25 h ago is deleted and `abort_multipart_upload` is called; one 23 h old is kept. **Step 2: Run** → FAIL. **Step 3: Implement** (24 h cutoff). **Step 4: Run** → PASS. **Step 5: Commit** `feat: expire abandoned attachment uploads`.

### Task 8: Web app uploads raw bytes and large files in parts

**Files:**
- Modify: `frontend/src/api/client.ts` (add `api.postRaw(path, body: Blob, query)` and `api.putRaw`, octet-stream, keep auth + `X-Vault-ID`), `frontend/src/api/queries.ts:678-701` (`useUploadAttachment` takes `File`), `frontend/src/viewer/attachment-upload/upload-files.ts`, `upload-dialog.tsx:63,82-110` (415 copy → "Executable files can't be uploaded"; remove base64)
- Create: `frontend/src/api/chunked-upload.ts` (`uploadInParts(file: File, path: string, opts: {partSize: number, onProgress?: (done: number, total: number) => void, signal?: AbortSignal}) => Promise<AttachmentMeta>`; resumes via status GET on retry)
- Test: `frontend/src/api/chunked-upload.test.ts`, `upload-dialog.test.tsx`, `upload-files.test.ts`

- [ ] **Step 1: Failing tests:** a 20 MiB `File` sends 3 PUTs with `file.slice` bounds `[0,8M) [8M,16M) [16M,20M)` then `complete`; a PUT that rejects once is retried after a status GET that skips done parts; a 1 MiB file uses one `postRaw`; the dialog shows the executable copy on 415. Part size comes from the server (`attachment_part_size` via the existing features/plan query), not a constant.
- [ ] **Step 2: Run** `cd frontend && bun run test -- chunked-upload upload-dialog upload-files` → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS; new strings through the i18n pipeline.
- [ ] **Step 5: Commit** `feat(web): raw and chunked attachment uploads`.

### Task 9: MCP + docs close-out

**Files:**
- Modify: `lib/engram/mcp/handlers.ex:675-718` (describe raw single upload for small files and the parts protocol above `max_body_bytes`, using the same token), `lib/engram/mcp/tools.ex:1238-1269` if the schema text names types; `mcp-tools.json` (regenerate: `mix engram.mcp.tools_json`)
- Modify: `docs/context/attachment-mime-whitelist.md` (rename section to "executable blocklist"; record why), new `docs/context/attachment-chunked-upload.md` (protocol, format v2, failure modes, how to read a trace)
- Test: `test/engram/mcp/*get_attachment_upload_target*` assertions on the new prose

- [ ] **Step 1: Failing test** on the handler output containing `/api/attachment-uploads` and not "whitelisted". **Step 2-4:** implement, run, regenerate `mcp-tools.json`. **Step 5: Commit** `docs: attachment upload protocol and blocklist`.

### Task 10: engram-infra backstop (separate repo, separate small PR)

- [ ] Add an `AbortIncompleteMultipartUpload` lifecycle rule (7 days) to the prod and staging attachment buckets in `engram-infra` Terraform; plan output shows only that change. Commit `feat: abort stale attachment multipart uploads`.

## Verification before PR

- [ ] `mise exec -- mix format --check-formatted && mise exec -- mix credo --strict && mise exec -- mix dialyzer`
- [ ] `mise exec -- mix sobelow --exit low --skip` (new `send_chunked` in `AttachmentRawResponse` may need a re-pin: `rm .sobelow-skips && mix sobelow --mark-skip-all`, count may only change by the new site)
- [ ] Targeted: every test file named above + `test/lint/` + `test/engram/logger/`. Full suite on CI only.
- [ ] Staging: upload a 300 MB file on a Pro test account from the web app, kill the network mid-upload, resume; download it; rotate the user's DEK; download again.
