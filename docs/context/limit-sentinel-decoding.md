# The four spellings of "no limit"

**Trigger:** you are reading a plan limit and about to write `case
Billing.effective_limit(user, :key) do :unlimited -> ...`, or an operator set a
`-1` override and the user got *more* restricted instead of less.

## The rule

`Billing.effective_limit/2` is the RESOLVER, not the decoder. It returns four
things and callers must not decode them by hand:

| value | means | reached by |
|---|---|---|
| `:unlimited` | enforcement off entirely | self-host, `ENGRAM_LIMITS_ENFORCED=false` |
| `nil` | this tier is unmetered | catalog default (`LimitKeys`) |
| `-1` | operator override meaning unlimited | `user_limit_overrides` row |
| an integer | a real ceiling | catalog default or override |

Use the decoders instead:

- **`Billing.cap(user, key)`** → `integer | nil`. All three "no cap" spellings
  collapse to `nil`.
- **`Billing.granted?(user, key)`** → `boolean`. The predicate half of
  `check_feature/2`; enforcement-off grants.
- `check_limit/3`, `limit_enforced?/2` — unchanged, and `limit_enforced?/2` is
  now defined as `cap(user, key) != nil` so the three cannot disagree.

## Why this doc exists

Before `cap/2`, eight modules decoded those four values privately under seven
different names — `normalize_cap`, `normalize_int`, `as_int`, `as_bool`,
`cap_json`, `bool_json`, `render_limit` — plus inline
`limit in [:unlimited, nil, -1]` guards in two plugs. **They did not agree, and
the disagreements were all about `-1`.** Four live bugs, all the same shape:

- `Engram.Accounts.Export` — `normalize_cap/1` knew only `:unlimited`, so `-1`
  arrived as a real ceiling and `count >= -1` refused **every export**.
- `Engram.ConversationMeter` — `day_cap_exceeded?/2` enumerated `:unlimited` and
  `nil` but not `-1`, so `today > -1` rate-limited the **first** MCP call.
- `Engram.ConversationMeter` — `normalize_int/2` let `-1` through as a
  **-1 minute** conversation window: every tick looked expired, rotated a new
  conversation, and burned `ai_conversations_per_day` in a few calls.
- `Engram.Search.SearchProfile` — `as_int/2` yielded `candidate_pool: -1` and
  `diversity: -0.01`.

In every case an override meaning "give this user unlimited" made them **more**
restricted than the default. That is the same enforcement-off-inverts-the-rule
shape as the `attachments_text_only` polarity bug in `LimitKeys` — a sentinel
decoded per-caller will eventually be decoded backwards by one of them.

## `cap/2` is the dial decoder; `limit_enforced?/2` + `check_limit/3` are the gate

`user_limit_overrides.value` is a bare `:map`. The changeset validates the KEY
against the catalog and **never the value's type**, so `%{"v" => "2000"}` is
storable. The two sides handle that differently, on purpose:

- **`cap/2` — fails OPEN.** A malformed value answers `nil`, same as every "no
  cap" spelling. That is what makes `cap(user, key) || default` safe, which is
  the entire reason the function exists: a dial or a progress bar must not raise
  on a corrupt row. `"30" / 100.0` is an `ArithmeticError`, and
  `SearchProfile.resolve/1` runs on every search.
- **`limit_enforced?/2` + `check_limit/3` — fail CLOSED.** Both read
  `effective_limit/2` directly and treat an unreadable value as a real ceiling,
  so the write is refused.

For a corrupt row they therefore **disagree on purpose**:
`limit_enforced?/2` says "there is a ceiling", `cap/2` says `nil`. A caller that
uses both — `Engram.Notes.check_notes_cap/2` is the pattern — refuses the write
and reports a null limit in the 402 body. Refusing is the safe half; showing a
fabricated number is not.

**Do not define one in terms of the other.** An earlier draft of this work had
`limit_enforced?/2` as `cap(user, key) != nil`, which quietly made the gate
inherit `cap/2`'s fail-open policy: a caller doing
`if limit_enforced?, do: check_limit` would skip the check entirely on a corrupt
row and GRANT. `Engram.BillingLimitPredicateTest` pins the safety property that
forbids it.

Dialyzer is the tripwire here. An intermediate version kept `cap/2`'s
`integer() | nil` spec while actually passing malformed values through, and a
defensive `not is_integer(limit)` clause downstream was flagged `neg_guard_fail`
— the spec was lying and the compiler said so. If you widen what `cap/2` can
return, that warning comes back.

Two modules keep their own resolution on purpose:
`Engram.Indexing.IndexCap.resolve_cap/1` returns `{:cap, n} | :unlimited` and
logs a warning before falling back to the tier default (fails CLOSED on
garbage, because the cap bounds Qdrant spend), and
`Billing.inactivity_warnings_exempt?/1` is `!= false` rather than `granted?`
because refusing THAT grant starts a deletion clock.

## Adding a limit key

`mix engram.lint.limit_keys` and `Engram.Billing.LimitEnforcementTest` both
treat `cap/2` and `granted?/2` as gate calls, so a key reached only through them
still counts as enforced. See also
[[mcp-bypasses-path-shaped-plugs]] for *where* the gate has to live.
