[
  # AAD helpers — `aad_for_row/3`, `aad_for_qdrant/3`, `aad_for_wrapped_dek/1` are
  # intentionally specced as `binary()` so callers don't depend on the exact byte
  # layout. Dialyzer's success typing (with the `:underspecs` flag) infers tighter
  # `<<_::N, _::_*8>>` shapes from the literal-string concatenation, but narrowing
  # the spec would leak implementation details to call sites and make any
  # caller-side `binary()` parameter type fail to match.
  {"lib/engram/crypto.ex", :contract_supertype, 71},
  {"lib/engram/crypto.ex", :contract_supertype, 82},
  {"lib/engram/crypto.ex", :contract_supertype, 91},

  # Dialyzer's success typing for `Path.rootname/1` (and possibly Regex helpers
  # called inside extract_title/2) reports a phantom `{integer(), integer()}`
  # return type that no real call path produces — every internal helper is
  # guarded with `is_binary/1`. Widening the spec to include the phantom would
  # mislead callers; ignoring the missing_range warning here is safe.
  {"lib/engram/notes/helpers.ex", :missing_range, 13}
]
