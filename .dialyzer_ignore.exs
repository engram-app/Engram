[
  # AAD helpers — `aad_for_row/3`, `aad_for_qdrant/3`, `aad_for_wrapped_dek/1` are
  # intentionally specced as `binary()` so callers don't depend on the exact byte
  # layout. Dialyzer's success typing (with the `:underspecs` flag) infers tighter
  # `<<_::N, _::_*8>>` shapes from the literal-string concatenation, but narrowing
  # the spec would leak implementation details to call sites and make any
  # caller-side `binary()` parameter type fail to match.
  # NOTE: dialyxir 1.4.x line-matches the `@spec` line, not `@doc`. Keep these
  # in sync if you re-order or add lines above the AAD helpers.
  {"lib/engram/crypto.ex", :contract_supertype, 85},
  {"lib/engram/crypto.ex", :contract_supertype, 94},

  # `identify_from_blob/1` is intentionally specced as `term()` because callers
  # pass values straight from DB columns (which may be nil) or from arbitrary
  # external input — the function gracefully handles every shape via the
  # `_other` catch-all clause. Dialyzer's success typing infers a narrower
  # binary-shape union from the leading three pattern matches, but the spec
  # has to remain `term()` so future callers don't fail type-check at the
  # boundary. Same pattern as the AAD helpers above.
  {"lib/engram/crypto/key_provider.ex", :contract_supertype, 71},

  # `decode_value/1`'s catch-all clause handles a Y.Map value written directly
  # over the Yjs wire protocol (apply_update/2) by a buggy or hostile peer,
  # bypassing Frontmatter's own JSON-string encoding entirely — e.g. a raw
  # number/bool/nil/nested-map. Every ACTUAL lib/ call site happens to route
  # through our own encode path (always a binary), so dialyzer's success
  # typing (correctly, for the code it can see) concludes the clause is dead.
  # It isn't: it's the only thing standing between a hostile CRDT write and a
  # bricked note (emit/2 must stay total). Verified by deleting the clause —
  # it breaks "emit degrades an unserializable value instead of raising" and
  # "emit tolerates a non-binary value" in frontmatter_test.exs.
  {"lib/engram/notes/frontmatter.ex", :pattern_match_cov, {408, 8}}
]
