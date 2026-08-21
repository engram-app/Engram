[
  # AAD helpers — `aad_for_row/3`, `aad_for_qdrant/3`, `aad_for_wrapped_dek/1` are
  # intentionally specced as `binary()` so callers don't depend on the exact byte
  # layout. Dialyzer's success typing (with the `:underspecs` flag) infers tighter
  # `<<_::N, _::_*8>>` shapes from the literal-string concatenation, but narrowing
  # the spec would leak implementation details to call sites and make any
  # caller-side `binary()` parameter type fail to match.
  # NOTE: dialyxir 1.4.x line-matches the `@spec` line, not `@doc`. Keep these
  # in sync if you re-order or add lines above the AAD helpers.
  {"lib/engram/crypto.ex", :contract_supertype, 86},
  {"lib/engram/crypto.ex", :contract_supertype, 95},

  # `identify_from_blob/1` is intentionally specced as `term()` because callers
  # pass values straight from DB columns (which may be nil) or from arbitrary
  # external input — the function gracefully handles every shape via the
  # `_other` catch-all clause. Dialyzer's success typing infers a narrower
  # binary-shape union from the leading three pattern matches, but the spec
  # has to remain `term()` so future callers don't fail type-check at the
  # boundary. Same pattern as the AAD helpers above.
  {"lib/engram/crypto/key_provider.ex", :contract_supertype, 71},

  # `Links.backlinks_limit/0` is intentionally specced as `pos_integer()`
  # rather than the literal `200` dialyzer infers from the current
  # `@backlinks_limit` value — the spec documents the contract callers (and
  # tests) can rely on, not today's specific cap. Same pattern as above.
  {"lib/engram/links.ex", :contract_supertype, 711},

  # `EmbedNote.backfill_priority/0` is intentionally specced as `pos_integer()`
  # rather than the literal `9` dialyzer infers from `@backfill_priority` — the
  # spec documents the contract ("some priority that loses to interactive"),
  # not today's value, so callers and tests don't bake the constant in a second
  # place. Same pattern as `Links.backlinks_limit/0` above.
  {"lib/engram/workers/embed_note.ex", :contract_supertype, 411},

  # `Links.live_basename_count/3` sums two `Repo.one(select: count(...))`
  # results. SQL `count()` is always a non-negative integer at runtime, but
  # `Repo.one/2` types as `term()`, so dialyzer widens the `+` to `number()`
  # and flags `float()` as missing from the `non_neg_integer()` spec. The
  # spec states the real contract.
  {"lib/engram/links.ex", :missing_range, 355}
]
