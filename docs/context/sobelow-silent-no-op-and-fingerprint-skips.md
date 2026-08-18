# Sobelow was a silent no-op, and the fingerprint skips that hid it

_Last verified: 2026-08-18 (sobelow 0.14.1 → 0.15.0, branch `chore/bump-mix-minor-deps`)_

## Status

Fixed. Sobelow now actually scans. 21 findings triaged (all false positives) and
pinned by fingerprint in `.sobelow-skips`; CI and the pre-push hook both run
`mix sobelow --exit low --skip`.

## The one idea

**Sobelow 0.14.1 was not scanning this project at all.** `mix sobelow --exit low`
printed its category guide and exited 0. Nothing else. So two gates were green on
a scan that never ran:

- the `Sobelow` step in `.github/workflows/verify.yml`, and
- the Stage B sobelow check in `.githooks/pre-push`.

This had been true for an unknown but long period. The "Phase 6" hardening comment
in `verify.yml` (which boasts about dropping `--skip` for maximum strictness) was
enforcing nothing at all: a stricter invocation of a program that does not run is
still a program that does not run.

The bump to **0.15.0** is what surfaced it. 0.15.0 fixed a family of silent-pass
bugs, any of which produce exit 0 with no scan:

- a `.sobelow-conf` could disable the scan entirely (`--save-config` used to write
  a `version` key into the file, so every later run just printed the version and
  exited 0),
- a corrupt or unreadable version-check cache aborted the scan while still exiting
  0, printing "This does not appear to be a Phoenix application",
- `# sobelow_skip` comments were silently discarded over whitespace variations,
- an empty or comment-only `.sobelow-conf` crashed or errored.

**Lesson to carry:** a security scanner that exits 0 has proven nothing until you
have watched it fail. See the verification recipe below, and run it any time the
sobelow invocation, config, or version changes.

## What turning it on surfaced: 21 findings, all false positives

Triaged individually. Recorded here so nobody re-derives the triage, and so the
few genuinely load-bearing invariants are written down.

### `Misc.BinToTerm` x4

`crypto.ex:580`, `crypto/user_dek_rotation.ex:1411`, `notes.ex:4597`, `notes.ex:4932`.

All already pass `[:safe]`, and all only ever decode bytes that just passed
AES-GCM authentication under a per-user DEK with row-bound AAD (the
`notes.tags_ciphertext` column, which holds `:erlang.term_to_binary(tags)`). An
attacker-substituted byte string fails the GCM tag check and returns `:error`
before `binary_to_term` is ever reached.

The adjacent `crypto/aad_rebind.ex:220` shares the same pattern and was not
flagged, which is itself a reminder that the check's coverage is uneven.

### `XSS.ContentType` + `XSS.SendResp` x5

`attachments` controller (401, 403), `oauth_authorize_controller` (119, 139),
`spa_controller` (7).

Attachment MIME is user-settable, and `MimeWhitelist` allows the whole `text/`
prefix, so `text/html` **can** be stored. Three things stop that from being a
stored-XSS vector:

1. `inline_safe?/1` is an **allowlist**: only `image/*` (minus svg),
   `application/pdf`, and `text/plain` get inline disposition. Everything else is
   force-downloaded.
2. The attachment route sits on the `:api` pipeline, which sets `nosniff` and
   `content-security-policy: default-src 'none'`.
3. Bearer auth means there is no drive-by navigation to the URL.

> **Hardening note, the one that matters.** The safety of the entire attachment
> serving path rests on `inline_safe?/1` staying an **allowlist**. Flip it to a
> denylist, or add a broad prefix to it, and stored HTML becomes servable inline.

The OAuth sites interpolate only hardcoded error-code literals and are HTML-escaped
anyway. `spa_controller` injects zero request data.

### `Traversal.FileModule` x4

All resolve through `Application.app_dir(:engram, "priv/...")` with literal
suffixes. The one dynamic case (`release/preflight.ex`) derives filenames from
`File.ls!` filtered by an anchored `^\d{14}_.+\.exs$` regex. Three are boot or
operator-only paths; `spa_controller.ex:58` is HTTP-reachable but its `index/2`
discards params entirely.

### `SQL.Query` x2

`attachments.ex:970`, `notes.ex:6582`.

Interpolation builds query **shape** only: `$N` placeholder tuples from
`Enum.with_index`, column names from the compile-time module attributes
`@marker_rename_cols` / `@v2_rename_cols` / `@v1_rename_cols`, and a whitelisted
`rename_col_sql_type/1`. Every actual value is a Postgrex bind parameter.

> **Forward-looking trap.** `bulk_rename_update!/3` is safe **because** `cols` is
> currently unreachable from runtime data. If someone later passes a
> caller-derived column list, the `set_sql` interpolation becomes a genuine
> injection point. Fingerprint skips will not re-fire on that change either
> (different line, yes, but the skip is regenerated wholesale). Guard it at review
> time.

### `Config.CSP` x1

`router.ex:128`, the `spa` pipeline. CSP genuinely **is** set: built at request
time by `EngramWeb.CSP.header/0` and applied at `router.ex:151`. The check only
recognises a literal static map passed to `put_secure_browser_headers`.

### `Config.CSWH` x3

`endpoint.ex:9/30/45`. All three sockets use
`check_origin: {__MODULE__, :check_origin, []}`, a custom MFA with a real
per-env allowlist. The check only understands literal `true` / `false` and
low-flags anything else.

### `Config.HTTPS` x1

`config/prod.exs`. TLS terminates at the edge by design (ALB in SaaS, operator
reverse proxy in self-host), documented at `prod.exs:3` and `runtime.exs:746`.
Sobelow reads only `prod.exs` and cannot see `runtime.exs`.

## The resolution, and why fingerprints and not an ignore list

Findings are pinned in `.sobelow-skips` by **fingerprint**
(`check,file:line,hash`), generated with `mix sobelow --mark-skip-all`. CI and the
pre-push hook both run:

```
mix sobelow --exit low --skip
```

An `ignore:` list of check names in `.sobelow-conf` was considered and rejected:
it permanently blinds whole **categories**. Ignoring `Misc.BinToTerm` means a
future genuinely-unsafe `binary_to_term` never fires. The fingerprint approach
keeps every category live and preserves the strictness Phase 6 was after; only
these 21 exact sites are muted.

### Verification recipe (re-run this whenever sobelow config or version changes)

Do not trust exit 0. Prove the scanner can still fail:

```bash
cat > lib/engram/zz_sobelow_canary.ex <<'EOF'
defmodule Engram.ZzSobelowCanary do
  def decode(bin), do: :erlang.binary_to_term(bin)
end
EOF
mix sobelow --exit low --skip; echo "exit=$?"
rm lib/engram/zz_sobelow_canary.ex
```

Verified 2026-08-18: exits **1** and names the new file. If it exits 0, sobelow is
not scanning and every green sobelow check on this repo is meaningless.

## Operational gotchas

- **`.sobelow-skips` must be registered in two fingerprint inputs**, or a stale
  green can be replayed over a changed skip list:
  - `BACKEND_HASH` inputs in `.github/workflows/verify.yml` (~line 333)
  - `ELIXIR_AFFECTING_REGEX` in `.githooks/pre-push` (~line 125)

  Both were updated. See `docs/context/ci-fingerprint-markers.md` for why an
  unregistered input is a correctness bug, not a cache miss.

- **CI and the pre-push hook invoke sobelow separately** (the `Sobelow` step in
  `verify.yml`, and Stage B in `.githooks/pre-push`) and must carry identical
  flags. The hook was missed on the first push attempt and rejected the push,
  which is how the flag drift got caught. Change one, change both.

- **Sobelow 0.15.0 does auto-read `.sobelow-conf`** (0.14.1 started this). The
  earlier assumption that CI must pass `--config` for an ignore list to be honoured
  was tested and is **false**. No `--config` flag is needed.

- **Line shifts invalidate fingerprints.** When a flagged file moves lines,
  regenerate with `mix sobelow --mark-skip-all` and re-triage anything new that
  appears in the diff. Do not hand-edit `.sobelow-skips`.

## Related

- `docs/context/ci-fingerprint-markers.md` (fingerprint inputs must cover every
  file that changes a job's result)
- `docs/context/ci-pipeline-gating.md` (which checks gate and which only report)
- `docs/context/attachment-mime-whitelist.md` (the MIME allowlist behind the
  `inline_safe?/1` argument above)
