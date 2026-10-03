# Sobelow was a silent no-op, and the fingerprint skips that hid it

_Last verified: 2026-10-03 (sobelow 0.15.0, 18 entries in `.sobelow-skips`)_

## The one idea

**Sobelow 0.14.1 was not scanning this project at all.** `mix sobelow --exit low`
printed its category guide and exited 0. So two gates were green on a scan that
never ran: the `Sobelow` step in `.github/workflows/verify.yml`, and Stage B of
`.githooks/pre-push`.

The bump to **0.15.0** surfaced it. 0.15.0 fixed a family of silent-pass bugs,
any of which produce exit 0 with no scan:

- a `.sobelow-conf` could disable the scan entirely (`--save-config` used to write
  a `version` key into the file, so every later run just printed the version and
  exited 0),
- a corrupt or unreadable version-check cache aborted the scan while still exiting
  0, printing "This does not appear to be a Phoenix application",
- `# sobelow_skip` comments were silently discarded over whitespace variations,
- an empty or comment-only `.sobelow-conf` crashed or errored.

**Lesson:** a security scanner that exits 0 has proven nothing until you have
watched it fail. Run the verification recipe below whenever the sobelow
invocation, config, or version changes.

## Triage of the pinned findings (all false positives)

Recorded so nobody re-derives the triage, and so the invariants each skip rests
on are written down. Line numbers live in `.sobelow-skips`, not here.

### `Misc.BinToTerm` x4

`crypto.ex`, `crypto/user_dek_rotation.ex`, `notes.ex` (x2).

All pass `[:safe]`, and all only decode bytes that just passed AES-GCM
authentication under a per-user DEK with row-bound AAD (the
`notes.tags_ciphertext` column, which holds `:erlang.term_to_binary(tags)`). An
attacker-substituted byte string fails the GCM tag check and returns `:error`
before `binary_to_term` is reached. These four are the **only** `binary_to_term`
call sites in `lib/`.

### `XSS.ContentType` + `XSS.SendResp` x3

`attachments_controller.ex` (x2) and `spa_controller.ex`.

Attachment MIME is user-settable and `MimeWhitelist` allows the whole `text/`
prefix, so `text/html` can be stored. The two load-bearing guards:

1. The attachment route is on the `:api` pipeline, which sets `nosniff` and
   `content-security-policy: default-src 'none'`, so a rendered SVG or HTML
   document executes nothing.
2. `EngramWeb.Plugs.Auth` matches `Bearer` on the `authorization` header ONLY,
   with no cookie or query-param fallback, so a victim who follows a link gets a
   401.

Protect those two. `inline_safe?/1` (inline only for `image/*` minus svg,
`application/pdf`, `text/plain`) is defense in depth. It normalizes the stored
MIME (strip parameters, trim, downcase) before matching, because an exact-string
`"image/svg+xml"` exclusion once let `image/svg+xml; charset=utf-8` through.

`spa_controller` injects zero request data.

### `Traversal.FileModule` x4

`legal/seeder.ex`, `release/preflight.ex`, `spa_controller.ex`,
`spa_integrity.ex`. All resolve through `Application.app_dir(:engram, "priv/...")`
with literal suffixes. The one dynamic case (`release/preflight.ex`) derives
filenames from `File.ls!` filtered by an anchored `^\d{14}_.+\.exs$` regex.
`spa_controller.ex` is HTTP-reachable but `index/2` discards params entirely.

### `SQL.Query` x2

`attachments.ex`, `notes.ex`.

Interpolation builds query **shape** only: `$N` placeholder tuples from
`Enum.with_index`, column names from the compile-time module attributes
`@marker_rename_cols` / `@v2_rename_cols` / `@v1_rename_cols`, and a whitelisted
`rename_col_sql_type/1`. Every actual value is a Postgrex bind parameter.

> **Forward-looking trap.** `bulk_rename_update!/3` is safe **because** `cols` is
> currently unreachable from runtime data. If someone later passes a
> caller-derived column list, the `set_sql` interpolation becomes a genuine
> injection point, and the fingerprint skip will not catch it. Guard it at review
> time.

### `Config.CSP` x1

`router.ex`, the `spa` pipeline. CSP **is** set: built at request time by
`EngramWeb.CSP.header/0` and applied in the pipeline. The check only recognises
a literal static map passed to `put_secure_browser_headers`.

### `Config.CSWH` x3

`endpoint.ex` (x3). All sockets use `check_origin: {__MODULE__, :check_origin, []}`,
a custom MFA with a real per-env allowlist. The check only understands literal
`true` / `false`.

### `Config.HTTPS` x1

`config/prod.exs`. TLS terminates at the edge by design (ALB in SaaS, operator
reverse proxy in self-host), documented in `prod.exs` and `runtime.exs`. Sobelow
reads only `prod.exs`.

## Fingerprints, not an ignore list

Findings are pinned in `.sobelow-skips` by **fingerprint**
(`check,file:line,hash`), generated with `mix sobelow --mark-skip-all`. CI and the
pre-push hook both run:

```
mix sobelow --exit low --skip
```

An `ignore:` list of check names in `.sobelow-conf` was rejected: it permanently
blinds whole **categories**. The fingerprint approach keeps every category live;
only the pinned sites are muted.

### Prefer fixing the shape over pinning it

A fingerprint defends a **location**. Where a cheap structural fix removes the
flagged shape, do that instead. Three original findings were removed this way:

- **`XSS.SendResp` x2 in `oauth_authorize_controller.ex`.** Hand-built HTML
  error strings now render `EngramWeb.OAuthAuthorizeHTML` (HEEx), so escaping is a
  property of the template. The render needs `put_format(:html)` explicitly: the
  route is on `:oauth_api`, whose `plug :accepts, ["json"]` negotiates a browser's
  `*/*` down to json.
- **`Config.CSRFRoute` x1 in `router.ex`.** `get`/`delete "/mcp"` shared one
  action, the exact shape the check keys on (`[controller, action]` per scope).
  Split into `:unsupported_transport_get` / `:unsupported_transport_delete`. Both
  still answer 405 + `allow: POST`, pinned by
  `test/engram_web/controllers/mcp_transport_test.exs`.

### What a fingerprint does NOT protect

`Sobelow.Finding.fingerprint/1` is `:erlang.phash2` of
`[check_type, vuln_source, filename, line]`, where `vuln_source` is the AST of
**the flagged call itself**. It covers neither the surrounding function nor where
the data came from.

Most skips are justified by **provenance**, not by the call. Review proved the
gap: replacing the authenticated decrypt feeding a skipped `binary_to_term` with
a plain `Base.decode64!` left `mix sobelow --exit low --skip` **silent at exit 0**.

| Change | Resurfaces? |
|---|---|
| Same check at a new file or line | yes |
| The flagged call itself edited (`[:safe]` dropped) | yes |
| File renamed, or lines inserted above | yes (fails closed, but noisy) |
| **The data reaching the call made untrusted** | **no** |

Keeping the invariants in the triage above true is a code-review responsibility,
not something CI checks.

### Regenerating: `rm` first

`mix sobelow --mark-skip-all` **APPENDS, it does not replace.** Re-running it
after a refactor leaves every superseded fingerprint in place; dead pins match
nothing, so the file silently becomes a graveyard. Always:

```bash
rm .sobelow-skips && mix sobelow --mark-skip-all
```

Then read the diff and re-triage. Regenerating is exactly when a genuinely new
finding can get pinned under cover of a churn diff. The entry COUNT should only
change if a finding was genuinely added or removed.

### Verification recipe (whenever sobelow config or version changes)

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

It must exit **1** and name the new file. If it exits 0, sobelow is not scanning
and every green sobelow check is meaningless. This proves new-location detection
only, not that the existing skips are still justified.

## Operational gotchas

- **`.sobelow-skips` must be registered in THREE places**, or a stale green can
  be replayed over a changed skip list:
  - `lint-config` in `ci/fingerprint/groups.sh`. **This is the one that gates
    the lint job**: `skip-lint` comes from `job_groups lint`, not `BACKEND_HASH`.
  - `BACKEND_HASH` inputs in `.github/workflows/verify.yml`
  - `ELIXIR_AFFECTING_REGEX` in `.githooks/pre-push`

  Also add a row to the `PAIRS` table in `ci/fingerprint/test/groups_test.sh`, or
  the static assertion cannot catch the omission. An unregistered input lets a
  skips-only PR hit an existing `ci-lint:<hash>` marker and skip sobelow
  entirely. See [ci-fingerprint-markers.md](ci-fingerprint-markers.md).

- **CI and the pre-push hook invoke sobelow separately** and must carry identical
  flags. Change one, change both.

- **Sobelow 0.15.0 auto-reads `.sobelow-conf`.** No `--config` flag is needed.

- **Line shifts invalidate fingerprints.** An unrelated edit above a flagged line
  fails the build with the finding re-reported at its new line. That reads like a
  new finding; it is correct fail-closed behaviour. Regenerate with the `rm`
  recipe above and re-triage. Do not hand-edit `.sobelow-skips`.

## Related

- [ci-fingerprint-markers.md](ci-fingerprint-markers.md): fingerprint inputs must
  cover every file that changes a job's result
- [ci-pipeline-gating.md](ci-pipeline-gating.md): which checks gate
- [attachment-mime-whitelist.md](attachment-mime-whitelist.md): the MIME allowlist
  behind the `inline_safe?/1` argument
