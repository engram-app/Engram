# Attachment chunked (resumable) uploads and content format v2

_Last verified: 2026-10-19_

Attachments of any size sync. A file up to `EngramWeb.Endpoint.max_body_bytes/0`
(11_000_000) goes up in one raw request; a larger file uses the parts protocol
below. The MCP tool `get_attachment_upload_target` tells an agent which to use
and returns the same token surface for both.

**Code:** `EngramWeb.AttachmentsController` (raw single request),
`EngramWeb.AttachmentUploadsController` (parts), `Engram.Attachments.Uploads`
(session logic), `Engram.Attachments.SegmentedCipher` (format v2),
`Engram.Workers.AttachmentUploadExpiry` (sweep). Contract: `openapi.json`.

## Single request (small files)

`POST /api/attachments?path=&mtime=[&mime_type=]`, `application/octet-stream`
body. Legacy base64 JSON still works. Refusals: 402 plan/size/quota, 408 stalled
body, 413 over the ceiling, 415 executable extension, 422 bad `mtime` or
`mime_type`, 502 storage, 503 `rotation_in_progress`.

## Parts protocol (large files)

Prefix is **`/api/attachment-uploads`**, not `/api/attachments/uploads`: the
`/api/attachments/*path` show/delete routes would swallow a vault file that
lives in an `uploads/` folder.

| Call | Success | Notes |
|---|---|---|
| `POST /api/attachment-uploads` json `{path, size_bytes, mime_type?}` | 201 `{upload_id, part_size, part_count}` | Same up-front refusals as the raw route, plus the open-session limits below. Clients must use the returned `part_size`. |
| `PUT /api/attachment-uploads/:id/parts/:n` (n from 1), octet-stream | 200 `{part}` | Every part is exactly `part_size` bytes except the last. Re-sending a part replaces it. 409 `upload_completed` once completed. |
| `GET /api/attachment-uploads/:id` | 200 `{done, part_count, part_size, completed}` | Resume: send what is not in `done`. `completed: true`: call complete again for the attachment. |
| `POST /api/attachment-uploads/:id/complete` | 200 `{attachment}` | Idempotent: a repeat on a completed session returns the same attachment, read fresh (404 if it was deleted or overwritten since). |
| `DELETE /api/attachment-uploads/:id` | 204 | Idempotent; an unknown, foreign or completed id is also 204 and touches nothing (a completed session's blob is the attachment's). |

Status codes by failure: 402 plan, size or quota (a file over 10,000 parts is
402 `file_too_large` on every plan); 404 unknown or foreign upload
(tenant-scoped, checked before the part body is read); 408 stalled body; 409
`missing_parts` with `missing: [..]` on complete, 409 `upload_completed` on a
part PUT to a completed session; 415 executable extension; 422
`bad_part_size` (an over-size part is 422, not 413), `bad_part_number`,
`invalid_mime_type`; 429 `too_many_uploads` with `retry-after: 10` on start; 501 `multipart_unsupported` (self-host database storage
has no multipart; the MCP tool omits `uploads_url` there); 502 storage failure; 503 `rotation_in_progress` with
`retry-after`.

Auth: the MCP OAuth token works on all five routes, like `POST /api/attachments`.
An `mcp:read` token gets 403 `read_only_grant`, a read-only vault 403
`read_only_vault`. All five routes, `GET` included, count as writes
(`EngramWeb.ReadOnlyRoutes`): a session only exists for a writer, and status
reveals upload progress.

## Content format v2 (`Engram.Attachments.SegmentedCipher`)

- A random per-file key seals the content; the user's DEK wraps only that key,
  with AAD bound to the attachment id. DEK rotation rewraps 32 bytes instead of
  re-encrypting the object, and rotation also rewraps in-flight session keys.
- One independently sealed segment per part: `nonce(12) || ciphertext || tag(16)`.
  Segment AAD = upload id + index + count + final flag, so reordered, swapped-in
  or truncated segments fail to open.
- No compression (the segment AAD prefix is outside the envelope compression
  policy). Sealed offset of segment `i` = `i * (segment_size + 28)`, which is
  what makes ranged reads and `Range` downloads cheap. `segment_size` on the row
  is the plaintext part size.
- Readers open segments using the row's stored `segment_count`.

## Decisions and why

- **Content hash is computed at complete by ranged read-back**, not while
  uploading: parts arrive out of order and repeat, so no running hash is valid.
- **A fresh blob key per write, v1 and v2.** The old blob is released only after
  the row commits. Before this, a v1 overwrite PUT onto the live row's key and
  then a refusal under the lock (quota re-check, rotation gate) rolled the row
  back with the live blob already clobbered, making a good attachment
  undecryptable. A refusal now deletes only the fresh blob.
- **Rotation gate.** Attachment writes check `RotationGate` inside the shared
  commit (v1 and v2) and in start/put_part, answering 503 `rotation_in_progress`.
  The commit also compares `users.dek_version` under `FOR SHARE` (and the session
  stores `dek_version`), so a rotation that completes between reading the DEK
  and committing cannot leave a row wrapped under a retired DEK.
- **Complete is idempotent.** The commit marks the session `completed_at` (and
  sets `attachment_id` to the committed row) in the same transaction as the
  row write, instead of deleting it. Why: a complete can outlive the edge
  timeout (Cloudflare ~100 s) after committing; a retry used to get 404, and
  the client reported failure and sent DELETE. The duplicate guard is now
  `UPDATE ... WHERE completed_at IS NULL` matching 0 rows, which rolls back;
  the loser then answers with the winner's attachment (the retry often lands
  while the first complete is still running). The web client defers a 404
  on a retried complete to one final status check.
  Abort and expiry delete only open sessions, so neither can touch a
  committed blob. Rotation skips completed sessions: nothing reads their key
  again, and it may be bound to a claimed id the commit replaced.
- **HEAD on a v2 raw show** is answered from the row (content-length, no
  storage reads); `EngramWeb.Endpoint.head_request?/1` recovers the verb
  `Plug.Head` rewrites.
- **Open sessions count at start.** An open session's parts sit in storage
  before complete counts them, and re-PUTting a part bumps `updated_at`, so
  the expiry sweep never fires on a session kept alive. Start therefore counts
  the user's open (not completed) sessions at their declared `size_bytes`
  against the quota, and caps them at 4 per user across vaults
  (`:too_many_uploads`, 429). Both checks run again under a per-user start
  lock (`attachment_upload_start:<user_id>`, not the quota lock, so a start
  never waits on a complete) at the insert. Complete still re-checks the
  quota against live usage, since a single-request upload does not count
  open sessions. The web client retries a 429 on start (and only that: a
  start whose answer was lost may have opened a session, and a resend would
  hold a second slot).
- **10,000 parts at most** (S3's ceiling). With `max_file_bytes` unlimited
  (the self-host default) nothing else bounds `part_count`; a large enough
  size also overflowed the int4 column and raised after the multipart had
  started. Start refuses `size_bytes > 10_000 * part_size` as `{:too_large,
  max}`, and any refusal or raise after the multipart starts aborts it.
- **Expiry.** `AttachmentUploadExpiry` sweeps sessions idle for 24 h and aborts
  their S3 multipart uploads. A completed session loses only its row, 24 h
  after completing. Vault purge (`CleanupVault`) also drops session blobs and
  aborts open multipart uploads. The S3 bucket lifecycle rule
  `abort-incomplete-multipart` (7 days, engram-infra `s3.tf`) is the backstop
  for anything the sweep misses.

## Known gaps

- **Cross-node DEK cache window (pre-existing, system-wide, notes too).**
  `DekCache` entries are not version-tagged and peer eviction is an async
  PubSub broadcast, so during a rotation a node can briefly encrypt under a
  retired DEK. The same-node case exists too (the flip invalidates the cache
  after commit). Root cause is the untagged cache; tracked as its own issue.
- A flip between the commit gate and `get_dek` surfaces as a 500
  `decrypt_failed` rather than a retryable 503; the session is kept and a retry
  works.
- **An overwrite aborts an in-progress v2 download.** The old blob is released
  right after the new row commits, so a streaming download (or a sequence of
  `Range` requests) reading the old object fails mid-body; the server drops
  the connection rather than send a short body as complete. There is no
  `ETag`/`If-Range` yet, so a client resuming with `Range` cannot tell the
  file changed under it.
- **Rolling deploy (expand-phase cost).** A node running a release from before
  format v2 cannot read v2 rows: while old and new nodes serve together, a
  download of a file uploaded through the parts protocol can fail on an old
  node until the rollout finishes.

## Reading a trace

Refusals on all of these routes emit the shared refusal telemetry
(`AttachmentRefusalTelemetry`). A chunked upload shows as one `start`, N
`put_part`, one `complete`; a client resuming shows a `GET` between parts.
Repeated `put_part` for the same `n` is a retry, not a bug.
