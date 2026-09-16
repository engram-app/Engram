# Consolidating onto a shared function drops tolerances nobody wrote down

_Last verified: 2026-09-15 (PR #1645, `Engram.Notes.Frontmatter.split/1`)_

## Status

Fixed and pinned by tests at both layers. The lesson is the durable part —
read this before the next "replace the hand-rolled copy with the shared helper"
change.

## The one idea

**Hand-rolled code encodes accepted input shapes that no test names.** When you
delete it in favour of a shared function, you inherit the shared function's
accepted shapes — and you silently drop every shape only the hand-rolled version
tolerated. The diff looks like pure deletion. The behaviour change is invisible.

So **consolidating a PARSER is categorically riskier than consolidating a
LOGGER.** A logger has one input shape and a visible output; if it is wrong you
see it. A parser's contract is the set of byte sequences it accepts, and that
set is almost never written down anywhere — not in the moduledoc, not in the
tests. Two implementations that agree on every input your suite happens to use
can disagree on the input your users actually send.

Before consolidating a parser, ask the only question that matters: **what does
each side accept that the other does not?** Diff the accepted-input sets, not
the code.

## The instance, because the shape recurs

`Engram.MCP.Handlers.format_get_note/1` parsed frontmatter with its own regexes,
matching the opening fence as `\A\x{FEFF}?---\r?\n`. Consolidation replaced them
with `Engram.Notes.Frontmatter.split/1`.

The shared codec was strictly **better** in one way: it handles a closing fence
at EOF, which the regex missed. It was strictly **worse** in another nobody
noticed: it matched the opening fence as the literal `"---\n"` only.

`@fence_line_pattern` and `@fence_eof_pattern` had always tolerated `\r` on the
**closing** fence. That is what made this survivable for so long — CRLF was
*half*-supported, so it looked supported.

Consequence, end to end:

1. Every note Obsidian writes on Windows is CRLF, so `split/1` returned
   `{nil, whole_text}` — "no frontmatter".
2. `fm_has_key?(nil, "title")` and `fm_has_key?(nil, "tags")` were therefore
   both false.
3. `body_has_h1?` could not compensate, because the body it was handed still
   started with `---`.
4. MCP `get_note` emitted a duplicate `# <title>` and a duplicate `**Tags:**`
   line — exactly what that de-duplication logic exists to prevent (#731).

**Nothing failed.** The suite had zero CRLF coverage, at any layer. Code review
caught it, not the tests. A green suite is evidence about the inputs the suite
uses, and a consolidation changes behaviour precisely on the inputs it does not.

### Two things about the fix worth copying

**Fix the codec, not the call site.** `strip_open_fence/1` now accepts both
`\r\n` and `\n`, so every caller of `split/1` benefits. Patching
`format_get_note/1` would have left every sibling caller broken on the same
input.

**Test the combination, not just each half.** The pinning tests cover CRLF
*combined with* a closing fence at EOF, which routes through `split_trailing/2`
rather than `@fence_line_pattern`. Each half worked alone — that is exactly how
the gap survived review of the codec itself.

## Line shifts re-invalidate `.sobelow-skips` on almost every merge

Not new, but it costs 10 minutes each time it is rediscovered, and it hit twice
on one branch here:

- 5 lines added to a router pipeline shifted the `:spa` pipeline's `Config.CSP`
  false positive from `router.ex:180` to `:185`.
- A 9-line function added near the top of `notes.ex` shifted two
  `Misc.BinToTerm` and one `SQL.Query` entry by exactly +12.

Both times the pre-push hook failed with what reads like a **new** security
finding. It is not; skips are pinned by fingerprint (`check,file:line,hash`), so
any change to line numbers *above* a pinned finding invalidates it.

Remedy and the 30-second triage are documented in full — including why the `rm`
is mandatory and why regenerating is itself a risk window — in
`docs/context/sobelow-silent-no-op-and-fingerprint-skips.md`. Do not re-derive
it; read that doc.

## Credo cannot see metadata keys built inside a helper

`Warning.MissedMetadataKeyInLoggerConfig` only sees keys passed **literally** at
a `Logger.*` call site. Keys assembled inside a helper — here
`Engram.Logger.Metadata.with_category/3` — are invisible to it.

So `cimd_host` had never been added to the dev/test formatter allowlist in
`config/config.exs`, and the field the `mcp-connector-refused` alert facets on
did not render in local or test output. Prod was fine, which is why it went
unnoticed: prod formats with `{:all_except, [:__sentry__]}`.

**Testing consequence:** assert metadata like this through
`Engram.Test.LogCapture.with_events/1` (the structured event), not
`ExUnit.CaptureLog.capture_log/1` (formatter output). The structured event is
what ships to Loki; the formatted string depends on a per-env allowlist that no
static check defends.

## References

- `lib/engram/notes/frontmatter.ex` — `split/1`, `strip_open_fence/1`,
  `split_trailing/2`
- `lib/engram/mcp/handlers.ex` — `format_get_note/1`, `fm_has_key?/2`,
  `body_has_h1?/1`
- `test/engram/notes/frontmatter_test.exs`,
  `test/engram/mcp/handlers_get_note_test.exs` — CRLF coverage at both layers
- `config/config.exs` — `:logger, :default_formatter` metadata allowlist
- `docs/context/sobelow-silent-no-op-and-fingerprint-skips.md` — fingerprint
  skips, regeneration, and what a fingerprint does not protect
