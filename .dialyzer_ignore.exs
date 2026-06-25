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

  # `use JokenJwks.DefaultStrategyTemplate` injects `init/1` via macro expansion.
  # The injected callback's success typing (derived from the GenServer macro chain)
  # doesn't match the module-level no_return inference that dialyzer makes for
  # the module's `init/1` wrapper. This is a library-level type mismatch in
  # JokenJwks that we cannot fix without patching the upstream dependency.
  # Adding y_ex to mix.lock (CRDT PR) causes PLT rebuild which first exposes
  # this pre-existing JokenJwks type issue.
  {"lib/engram/auth/clerk_strategy.ex", :no_return, 10}
]
