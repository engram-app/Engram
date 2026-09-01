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

## Two failure directions, on purpose

Garbage (a malformed override value that is not an integer) is handled
differently on the two sides, and this is deliberate:

- **Gate side** — `cap/2` hands the value through as a ceiling, so
  `check_limit/3` refuses. Fails CLOSED. `cap/2` must agree with
  `limit_enforced?/2` here or a caller that reorders
  (`if limit_enforced?, do: check_limit`) silently skips a real cap.
  `Engram.BillingLimitPredicateTest` pins that agreement.
- **Wire side** — `BillingController.cap_json/1` and
  `Billing.normalize_capability/2` render it as `null` / no cap. Fails OPEN,
  because a corrupt row must not 500 the billing endpoint.

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
