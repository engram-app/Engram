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
| `POST /api/attachment-uploads` json `{path, size_bytes, mime_type?}` | 201 `{upload_id, part_size, part_count}` | Same up-front refusals as the raw route. Clients must use the returned `part_size`. |
| `PUT /api/attachment-uploads/:id/parts/:n` (n from 1), octet-stream | 200 `{part}` | Every part is exactly `part_size` bytes except the last. Re-sending a part replaces it. |
| `GET /api/attachment-uploads/:id` | 200 `{done, part_count, part_size}` | Resume: send what is not in `done`. |
| `POST /api/attachment-uploads/:id/complete` | 200 attachment | Safe to retry. |
| `DELETE /api/attachment-uploads/:id` | 204 | Idempotent; a consumed or foreign id is also 204 and touches nothing. |

Status codes by failure: 402 plan, size or quota; 404 unknown or foreign upload
(tenant-scoped, checked before the part body is read); 408 stalled body; 409
`missing_parts` with `missing: [..]` on complete; 415 executable extension; 422
`bad_part_size` (an over-size part is 422, not 413), `bad_part_number`,
`invalid_mime_type`; 501 `multipart_unsupported` (self-host database storage
has no multipart); 502 storage failure; 503 `rotation_in_progress` with
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
- **Expiry.** `AttachmentUploadExpiry` sweeps sessions idle for 24 h and aborts
  their S3 multipart uploads. The S3 bucket lifecycle rule
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

## Reading a trace

Refusals on all of these routes emit the shared refusal telemetry
(`AttachmentRefusalTelemetry`). A chunked upload shows as one `start`, N
`put_part`, one `complete`; a client resuming shows a `GET` between parts.
Repeated `put_part` for the same `n` is a retry, not a bug.
