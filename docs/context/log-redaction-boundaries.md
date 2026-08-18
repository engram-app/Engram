# Redacting paths out of log lines: the boundary problem

**Read this before touching `lib/engram/logger/redact_filter.ex`, or before adding a
log line anywhere near a vault path.**

## The requirement

> "I don't want there to be any way to log or send note content."

Note bodies, vault **paths**, titles and search queries are all sensitive. A folder
named `Medical/` or `Divorce 2026/` discloses the sensitive fact without anyone
reading the note. Logs ship to CloudWatch and Loki, **outside** the per-user
encryption boundary — so a path in a log line is a path in cleartext, permanently.

## Two mechanisms, and which one to reach for

| | mechanism | use when |
|---|---|---|
| **Our own call sites** | `Metadata.safe_reason/1`, key-based scrub in `RedactFilter` | always — you control the call site |
| **Dependency lines** | `truncate_at_separator/1`, gated on `@url_logging_modules` | never by choice; `ExAws` and `Req` log URLs from inside the dep |

**At your own call sites this doc does not apply.** Pass a label, not a path:
`safe_reason(reason)` renders a stable tag, and `storage_key:`/`path:`/`content:` are
scrubbed by key. The source guard in `test/engram/logger/log_call_compliance_test.exs`
fails the build if you interpolate a path-shaped variable into a log message.

The rest of this doc is about the one seam where we do **not** control the call site.

## The trap: every boundary is a guess at where the path ENDS

A dependency hands us prose with a path somewhere inside it. To redact "just the
path" you must know where it stops. **Nothing in a log line marks that.** Three
boundaries were shipped and all three leaked, each in a way its own tests missed:

| boundary | what it did | the shape that beat it |
|---|---|---|
| **per token** (`\S+`) | redact whitespace-delimited tokens containing a separator | a path with spaces — `.../Medical/2026 biopsy results.md` shipped `biopsy` and `results.md` in clear. Vault paths contain spaces constantly. |
| **per iolist element** | redact any element containing a separator, then join | a path split across elements — `["Medical/", "biopsy.md"]` → `[REDACTED]biopsy.md`. Worse: that case was **clean** under the token rule. Also raised on improper lists (`["a " \| "b"]`), which are legal iodata. |
| **per quoted span** | redact `"…/…"` whole | matched `[\/\\]` while `@separators` also lists `%2F`/`%5C`/`%25`; the two lists disagreed and the encoded form fell through. |

Each fix was a correct response to the previous failure and introduced the next one.
The pattern to recognise: **if your rule needs to know where the path ends, it will
have a shape it does not cover, and you will not think of that shape.**

## What is there now

`truncate_at_separator/1` keeps the prose up to the first token holding a separator
and drops **everything after it**. It never decides where the path stops, so a space,
an element boundary, a quote and an encoding are all non-issues rather than cases to
enumerate. Flattening happens first, so split paths and improper lists are handled by
construction.

**Cost, stated so nobody re-litigates it:** `ExAws` puts `ATTEMPT: 3` *after* the URL,
so the retry count is lost. Our own storage logging carries `storage_code` through
`safe_reason/1`, so the dependency line is supplementary. That trade is deliberate.

## Two things that will bite you

**`RedactFilter` is a PRIMARY `:logger` filter.** OTP **deletes** a primary filter
that raises, throws or exits — node-wide, for the life of the VM. One malformed event
would silently disable *all* redaction. Hence the `catch _, _` (not `rescue`, which
only covers the `:error` class). Anything you add here must not be able to raise, and
"the catch arm saves it" is not good enough: the catch arm blanks the line.

**It runs in the CALLING process.** Cost is caller latency, not background work. An
earlier regex was quadratic — 282 seconds on 100 KB. `@max_scrub_bytes` (32 KB) fails
closed above that.

## Testing it: the trap that hid all of this

Eight rounds of unit tests hand-built `{:string, "..."}` with tidy, space-free paths
and passed green through every leak above. What found them:

- **`test/engram/logger/no_note_content_at_sink_test.exs`** — drives real failures
  through the **real** primary filter and the **real** prod formatter
  (`LoggerJSON.Formatters.Basic`, `{:all_except, [:__sentry__]}`) and greps the JSON.
  Do not use `capture_log`: it renders the *dev* text formatter, whose `metadata:`
  allowlist omits keys prod emits, so a leak in `:error` metadata is invisible to it
  and fully visible in production. Do not apply `RedactFilter` inside the test either
  — it is installed at boot in every env (`application.ex:138`), so calling it again
  masks bugs that only show on first application.
- **Assert in BOTH directions.** A `refute`-only test passes just as happily when the
  filter has blanked every line — which is exactly what the catch arm does. Every
  assertion names something that must **survive**.
- **Mutation-prove it.** Revert the fix, confirm the test goes red, and verify the
  mutation actually applied (check occurrence counts) before concluding anything.
  Silently-unapplied mutations produced two false conclusions in this workstream —
  once "unpinned" when it was pinned, once the reverse. Green CI never caught a single
  one of these defects; the mutation table caught all of them.

## Related

- `docs/context/e2e-clerk-failure-taxonomy.md` — real bug vs flake vs lying oracle
- `../engram-workspace/docs/context/oauth-e2e-pairing-and-token-binding.md` — changing
  a log line an e2e asserts on deadlocks both PRs
