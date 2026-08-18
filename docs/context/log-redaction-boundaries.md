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
| **Dependency lines** | message DROPPED wholesale, gated on `@url_logging_modules` | never by choice; `ExAws` and `Req` log URLs from inside the dep |

**At your own call sites this doc does not apply.** Pass a label, not a path:
`safe_reason(reason)` renders a stable tag, and `storage_key:`/`path:`/`content:` are
scrubbed by key. The source guard in `test/engram/logger/log_call_compliance_test.exs`
fails the build if you interpolate a path-shaped variable into a log message.

The rest of this doc is about the one seam where we do **not** control the call site.

## The trap: every boundary is a guess at where the path IS

A dependency hands us prose with a path somewhere inside it. To redact "just the
path" you must know where it starts and stops. **Nothing in a log line marks
either.** Four boundaries shipped and all four leaked, each in a way its own tests
missed:

| boundary | what it did | the shape that beat it |
|---|---|---|
| **per token** (`\S+`) | redact whitespace-delimited tokens containing a separator | a path with spaces — `.../Medical/2026 biopsy results.md` shipped `biopsy` and `results.md` in clear. Vault paths contain spaces constantly. |
| **per iolist element** | redact any element containing a separator, then join | a path split across elements — `["Medical/", "biopsy.md"]` → `[REDACTED]biopsy.md`. Worse: that case was **clean** under the token rule. Also raised on improper lists (`["a " \| "b"]`), which are legal iodata. |
| **per quoted span** | redact `"…/…"` whole | matched `[\/\\]` while `@separators` also lists `%2F`/`%5C`/`%25`; the two lists disagreed and the encoded form fell through. |
| **prefix truncation** | keep the prose up to the first token holding a separator, drop the rest | a **space in the first folder name** — `["redirecting to ", "Medical Records/2026/biopsy.md"]` → `"redirecting to Medical [REDACTED]"`. It stopped guessing where the path *ends* and started guessing where it *begins*. |

Each fix was a correct response to the previous failure and introduced the next one.
Two further leaks needed no new rule at all: a filename with **no separator**
(`biopsy.md`), and `inspect/1` truncating a non-UTF-8 key at **100 bytes** so the
byte-render regex stopped matching and the path shipped as recoverable decimals.

**The pattern, once four data points make it visible:** every rule tried to keep SOME
of a string we do not author, and each needed a boundary — where the path starts,
where it ends — that nothing in the text actually marks. There is always another
shape, and it is by definition the one nobody thought of.

## What is there now

**The message is dropped, not scrubbed.** For the two modules in
`@url_logging_modules`, the entire message is replaced with `[REDACTED]`. Nothing is
parsed, so there is no boundary to get wrong and no shape to enumerate.

**What survives, and why this is not a real diagnostic loss:** `meta` is ours and is
untouched — `mfa` names the module and function, the level is intact, and our own
correlation ids ride along. The error KIND is not lost either: `storage/s3.ex` logs
`reason: safe_reason(reason)`, which renders `http_error 403 AccessDenied`. The
dependency line was always supplementary to that.

**Cost, stated so nobody re-litigates it:** `ATTEMPT: 3` and the ExAws
`debug_requests` dump. That dump carried a live SigV4 signature and attachment bytes,
so losing it is a second win rather than a cost.

This also closed a gap the scrub rules never could: they matched only
`{:string, chardata}`, so an Erlang-style `{format, args}` or `{:report, _}` from one
of these modules skipped redaction entirely. Nothing reads the message now, so every
shape is covered — and nothing here can raise.

## Two things that will bite you

**`RedactFilter` is a PRIMARY `:logger` filter.** OTP **deletes** a primary filter
that raises, throws or exits — node-wide, for the life of the VM. One malformed event
would silently disable *all* redaction. Hence the `catch _, _` (not `rescue`, which
only covers the `:error` class). Anything you add here must not be able to raise, and
"the catch arm saves it" is not good enough: the catch arm blanks the line.

**It runs in the CALLING process.** Cost is caller latency, not background work. An
earlier regex was quadratic — 282 seconds on 100 KB, blocking the caller. The size cap
that bounded it (`@max_scrub_bytes`) is **gone**, along with the scrub it protected:
dropping the message is O(1), so there is nothing left to bound. If you ever reinstate
parsing here, reinstate a cap with it.

## Testing it: the trap that hid all of this

Nine rounds of unit tests hand-built `{:string, "..."}` with tidy, space-free paths
and passed green through every leak above. What found them:

- **`test/engram/logger/no_note_content_at_sink_test.exs`** — drives real failures
  through the **real** primary filter and the **real** prod formatter
  (`LoggerJSON.Formatters.Basic`, `{:all_except, [:__sentry__]}`) and greps the JSON.
  Do not use `capture_log`: it renders the *dev* text formatter, whose `metadata:`
  allowlist omits keys prod emits, so a leak in `:error` metadata is invisible to it
  and fully visible in production. Do not apply `RedactFilter` inside the test either
  — it is installed at boot in every env (`application.ex:138`), so calling it again
  masks bugs that only show on first application.
- **Assert in BOTH directions, and COUNT.** A `refute`-only test passes just as
  happily when the filter has blanked every line — which is exactly what the catch arm
  does. Every assertion names something that must **survive**. It must also assert HOW
  MANY lines survive: with `Enum.any?`, blanking one of three lines in a loop stayed
  green, and review had to find it.
- **Mutation-prove it.** Revert the fix, confirm the test goes red, and verify the
  mutation actually applied (check occurrence counts) before concluding anything.
  Silently-unapplied mutations produced two false conclusions in this workstream —
  once "unpinned" when it was pinned, once the reverse. Green CI never caught a single
  one of these defects; the mutation table caught all of them.

## Related

- `docs/context/e2e-clerk-failure-taxonomy.md` — real bug vs flake vs lying oracle
- `../engram-workspace/docs/context/oauth-e2e-pairing-and-token-binding.md` — changing
  a log line an e2e asserts on deadlocks both PRs
