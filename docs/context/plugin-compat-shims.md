# Plugin compat shims

_Last verified: 2026-10-06_

A compat shim is server code kept only so plugins older than the current
release keep working after the wire changed (a new request shape, a new
feature the plugin opts into). Every shim carries one greppable marker:

```
# compat(plugin): <capability> - remove when plugin floor >= <version> (#issue)
```

A shim written before its plugin change has shipped cannot name a version
yet, so it names the plugin PR instead:

```
# compat(plugin): <capability> - remove when plugin floor includes Engram-obsidian#<pr> (#issue)
```

Once that PR ships in a plugin release (release-please cuts the version),
replace `includes Engram-obsidian#<pr>` with `>= <version>` in every marker
and in the table below. Never write `>= next`: a word cannot be compared
against a floor, and nobody comes back to fill it in.

Find them all with `grep -rn 'compat(plugin)' lib/`. The plugin's mirror
image, a fallback for backends older than the plugin (self-hosters upgrade
late), is marked `// compat(server): ...` in the plugin repo.

New wire shapes the plugin must detect before using are advertised in the
`user:{id}` join reply under `features` (`EngramWeb.UserChannel`).

Some flags advertise a behavior with no old shape kept, so they have no shim
and no row in the table below; they stay as long as a supported plugin reads
them. Ship such a flag one release AFTER the behavior it advertises: during a
rolling deploy a socket can join a new task (flag on) while its requests still
reach an old one.

- `attachment_batch_delete_origin` (planned, #2361): `POST
  /attachments/batch-delete` stamps the caller's `X-Device-Id` on every delete
  broadcast (since #2360). The plugin batches attachment deletes only when the
  flag is true (Engram-obsidian#671), and until then falls back to serial
  single deletes, which already stamp it, so it is safe without the flag.
  `EngramWeb.AttachmentBatchDeleteTest` pins the stamping and, until #2361,
  the flag's absence.

## The rule

When the plugin version floor is raised (workspace
`docs/context/plugin-version-floor.md`), delete every shim whose version is
at or below the new floor, its `features` key once no supported plugin reads
it, and its row below. Check the "also used by" column first: a shim another
client still calls is not dead yet.

| Capability | Shim location | Plugin version that no longer needs it | Also used by | Issue |
|---|---|---|---|---|
| `raw_attachment_upload` | `AttachmentsController.do_upload_gated/4` JSON branch; `Attachments.attachment_bytes/1` base64 clause | Engram-obsidian#555 (replace with its release version once shipped) | Web SPA (`frontend/src/viewer/attachment-upload/`, `useUploadAttachment`) and e2e helpers (`e2e/helpers/api.py`) still send base64 JSON; switch them first | #1877 |
| `raw_attachment_download` | `AttachmentsController.show/2` JSON (`content_base64`) branch | Engram-obsidian#555 (replace with its release version once shipped) | e2e helpers (`e2e/helpers/api.py` `get_attachment`, used by `test_19_write_isolation`, `test_73_free_attachment_402`) read the JSON body; switch them to `?raw=1` first. The web SPA already downloads with `?raw=1` | #1877 |
