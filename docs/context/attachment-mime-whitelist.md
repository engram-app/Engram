# Attachment MIME / Extension Whitelist (Pricing v2 §H)

Two-phase abuse defense against using Free vault storage as a malware /
illegal-content cache. Phase 1 ships at pricing v2 launch; Phase 2 is
deferred but the milestone trigger is documented here.

## Phase 1 — shipped

**Module:** `Engram.Storage.MimeWhitelist`
**Wired into:** `EngramWeb.AttachmentsController.upload/2`
**Rejection status:** HTTP 415 with `{"error": "mime_not_allowed", "mime_type": "..."}` or `{"error": "extension_not_allowed", "extension": "..."}`

### What's allowed

- Prefix-allowed: `image/*`, `audio/*`, `video/*`, `text/*`
- Explicitly allowed: `application/pdf`, `application/json`, Office formats
  (`.docx` / `.xlsx` / `.pptx` MIMEs + legacy `application/msword`,
  `application/vnd.ms-excel`, `application/vnd.ms-powerpoint`),
  OpenDocument formats, `application/rtf`.

### What's blocked

- MIME: `application/octet-stream` (the malware default), `application/zip`,
  `application/x-msdownload`, `application/x-dosexec`,
  `application/x-mach-binary`, `application/x-elf`, `application/x-sh`,
  anything not on the allowlist.
- Extension (belt-and-braces, applied even when MIME claims something
  allowlisted): `.exe`, `.dll`, `.com`, `.scr`, `.bat`, `.cmd`, `.vbs`,
  `.vbe`, `.ps1`, `.psm1`, `.msi`, `.msp`, `.app`, `.dmg`, `.pkg`, `.deb`,
  `.rpm`, `.apk`, `.ipa`, `.jar`, `.class`, `.sh`, `.bash`, `.zsh`, `.fish`,
  `.so`, `.dylib`, `.lnk`, `.reg`, `.hta`, `.cpl`, `.gadget`, `.iso`.

### Self-host operator knobs

- `ATTACHMENT_MIME_BYPASS=true` — disables the gate entirely. Use case:
  internal tool distribution from a self-hosted vault.
- `ATTACHMENT_MIME_ALLOWLIST_EXTRA=mime1,mime2` — extend the MIME
  allowlist without bypassing extension checks. Use case: archive-heavy
  team wants `application/zip` allowed.

Both default off. SaaS (`app.engram.page`) does not set either.

## Phase 2 — deferred

**Trigger:** schedule PhotoDNA / DMCA review when active Free users
crosses ~500. Below that threshold, the legal-risk surface is small
enough that Phase 1 + Paddle's MoR ToS coverage is sufficient.

**Tasks at trigger:**

1. Legal counsel review — CSAM scanning carries NCMEC reporting
   obligations in the US.
2. Apply to Microsoft PhotoDNA Cloud Service (free for qualifying orgs).
3. Wire image upload path to PhotoDNA hash check on the way in;
   maintain a write-side queue if the API is rate-limited.
4. DMCA response procedure documented + designated agent registered
   with the US Copyright Office.

**Decision owner:** founder + counsel. Not a launch blocker.

## Why not content sniffing in Phase 1?

The launch gate is intentionally cheap and conservative: extension +
client-declared MIME, no magic-byte sniffing. A client lying about MIME
and extension *can* slip a non-allowlisted payload past Phase 1, but the
attacker's blob also has to be opened by a victim who clicked through —
which means the extension is what the OS uses, which means our blocklist
catches it. Phase 2 PhotoDNA addresses the residual image-payload case.

## Operator launch checklist

1. Decide policy for SaaS: gate ON by default. No env vars needed on
   Fly — module defaults match the SaaS posture.
2. For self-host docs, add a note to `engram.ax` quick-start docs that
   `ATTACHMENT_MIME_BYPASS=true` is available for operators who need to
   distribute executables from their personal vault.
3. Re-evaluate the deny list quarterly — new RCE-bearing extensions
   appear (`.lnk` joined recently; `.url` and `.scf` are emerging).

## Test surface

- Unit: `test/engram/storage/mime_whitelist_test.exs` — 20 cases
  covering prefix allow, explicit allow, MIME reject, extension reject,
  bypass, operator extras.
- Controller: `test/engram_web/controllers/attachments_controller_test.exs`
  — added 3 cases (`.exe` belt-and-braces, `x-msdownload`, unknown
  extension defaults).
- E2E: `e2e/tests/api_only/test_70_attachment_mime_whitelist.py` — full
  API round-trip including PDF accept.
