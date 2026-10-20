# Attachment executable blocklist (was the MIME / extension whitelist, Pricing v2 §H)

_Last verified: 2026-10-19_

Two-phase abuse defense against using Free vault storage as a malware /
illegal-content cache. Phase 1 ships at pricing v2 launch; Phase 2 is
deferred but the milestone trigger is documented here.

## Phase 1 - shipped

**Module:** `Engram.Storage.MimeWhitelist`
**Enforced in:** `Engram.Attachments.upsert_attachment/3`, so REST, MCP, Oban and console callers all hit it. `AttachmentsController` also checks it to shape the 415, after the Free-tier text-only gate (402).
**Normalization:** decisions use `MimeWhitelist.normalize/1` (params stripped, trimmed, downcased); `\n`, `\r` and `\0` are rejected before normalizing. The stored MIME is the uploader's exact string.
**Rule:** every file type is accepted EXCEPT executables, judged on the file's last extension (case-insensitive), whatever `mime_type` the client claims. `blocked_extensions/0` returns the list.
**Rejection status:** HTTP 415 `{"error": "extension_not_allowed", "extension": ".exe"}`; a `mime_type` containing `\n`, `\r` or `\0` is HTTP 422 `{"error": "invalid_mime_type"}` (it is stored verbatim and would 500 on every read).

### Executable blocklist (extensions)

`.exe`, `.dll`, `.com`, `.scr`, `.bat`, `.cmd`, `.vbs`, `.vbe`, `.ps1`, `.psm1`, `.msi`, `.msp`, `.app`, `.dmg`, `.pkg`, `.deb`, `.rpm`, `.apk`, `.ipa`, `.jar`, `.class`, `.sh`, `.bash`, `.zsh`, `.fish`, `.so`, `.dylib`, `.lnk`, `.reg`, `.hta`, `.cpl`, `.gadget`, `.iso`, `.msix`, `.msixbundle`, `.appx`, `.appxbundle`, `.appimage`, `.run`, `.xpi`, `.crx`.

Why a blocklist: an allowlist silently failed legitimate vault files and an attachment is just bytes we never execute, so only double-click executables are refused. Large files are covered by `attachment-chunked-upload.md`.

Double-click executables only: source languages (`.js`, `.py`) are NOT blocked. The earlier MIME allowlist (which refused `.zip`, `.epub`, fonts, unknown types) was removed because it silently failed legitimate vault files.

### Self-host operator knob

- `ATTACHMENT_MIME_BYPASS=true` - disables the extension blocklist. A `mime_type` with CR, LF or NUL is still refused (422 `invalid_mime_type`). Use case: internal tool distribution from a self-hosted vault. Default off; SaaS does not set it. (`ATTACHMENT_MIME_ALLOWLIST_EXTRA` no longer exists.)

## Phase 2 - deferred

**Trigger:** schedule PhotoDNA / DMCA review when active Free users
crosses ~500. Below that threshold, the legal-risk surface is small
enough that Phase 1 + Paddle's MoR ToS coverage is sufficient.

**Tasks at trigger:**

1. Legal counsel review - CSAM scanning carries NCMEC reporting
   obligations in the US.
2. Apply to Microsoft PhotoDNA Cloud Service (free for qualifying orgs).
3. Wire image upload path to PhotoDNA hash check on the way in;
   maintain a write-side queue if the API is rate-limited.
4. DMCA response procedure documented + designated agent registered
   with the US Copyright Office.

**Decision owner:** founder + counsel. Not a launch blocker.

## Why not content sniffing in Phase 1?

The gate is intentionally cheap: extension only, no magic-byte sniffing. A client lying about the
extension *can* slip a payload past Phase 1, but the
attacker's blob also has to be opened by a victim who clicked through -
which means the extension is what the OS uses, which means our blocklist
catches it. Phase 2 PhotoDNA addresses the residual image-payload case.

## Tests

- `test/engram/storage/mime_whitelist_test.exs`
- `test/engram_web/controllers/attachments_controller_test.exs`
- `e2e/tests/api_only/test_70_attachment_mime_whitelist.py`
