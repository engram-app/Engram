# Plugin compat shims

_Last verified: 2026-11-17_

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
| `moved_folder_feed` | `Engram.Notes.list_moved_changes/4` (the third feed in `Engram.Sync.build_page/8`) and its attachment leg `Engram.Attachments.list_moved_changes/4` (the fourth: a delete at the stored path then an upsert at the shown path, one `(seq, id)` key, never split across pages; S6 step 6), gated per socket by `Engram.Sync.moved_feed?/1` from `CrdtChannel`'s `crdt_catchup_since`; `Notes.moved_head/2` behind `/sync/quiescence`'s `feed_seq_moved`. S5 (`Engram.Folders.WriteStop`) moves a folder as one row, so its notes keep their seq; a pre-S4 plugin learns the move only from this feed (an upsert with an id at the new path, applied as an id-keyed move, in note-id order because 1.39.x keeps the max `(seq, id)` it saw as its cursor), and learns a later delete of such a note from the same feed (an upsert at its tombstone path first). Once it goes, also drop `Location.s5_reads/0` level 2, `WriteStop`'s `@fleet_level`, `feed_seq_moved` and the e2e helper's version pick (`e2e/helpers/quiescence.py`) | None yet. `WriteStop.s4_plugin/0` is a `999.0.0` sentinel: 1.40.0 (Engram-obsidian#689) shipped without working moved-folder handling (e2e test_108). Lower it only per the "Preconditions to lower `s4_plugin`" in `WriteStop`'s moduledoc, after setting `@verified_folder_move_plugin` (guarded by `WriteStopFloorTest`) | Web SPA sends no `plugin_version` (gets the feed; it does not call catch-up); e2e quiescence reads both heads. The manifest's moved seq (`Location.listing_seqs/1`) and the shown-path announces are NOT shims: every client needs them | #2523 |
| `name_taken` | `EngramWeb.CrdtChannel.name_taken_terminal?/1` (and the `caps` parse in `EngramWeb.UserSocket`): a crdt_create refused because a live note holds the path replies `create_failed` unless the socket connected with `caps=name_taken` (or joined as `client_type: "web"`), then `id_conflict`. Plugins 1.36.0 to 1.40.0 drop an `id_conflict` create with only a log line (a silent loss), so they must keep the retryable reply. The relocate occupant's `id_conflict` predates this and is NOT gated | Engram-obsidian#727 (replace with its release version once shipped). Do not gate on a version: a plugin release can ship before #727 | Web SPA: counted capable by `client_type: "web"` (`isNameTaken` reads both replies); once the shim goes it needs nothing | #2722 |
| `no_version_blind_push` | `EngramWeb.WriteActor.requires_base?/1` user-agent clause (`obsidian_user_agent?/1`) | 1.29.0 (first release sending `X-Plugin-Version`), and only once `RequirePluginVersion` refuses a MISSING header: today a missing header passes, so the floor alone does not retire pre-1.29.0 plugins. The `X-Plugin-Version` clause beside it is not a shim: current plugins also push without a base | none | #2480 |
