# Task 3: Frontmatter `parse/1` Review Fixes

## Summary
Fixed two review findings in `Engram.Notes.Frontmatter.parse/1`:
1. Replaced raising `Jason.encode!/1` with non-raising `Jason.encode/1`
2. Added three new test cases covering nested maps, inline colons, and bare lists

## Changes

### Implementation (`lib/engram/notes/frontmatter.ex`)
- Changed parse/1 from direct `Jason.encode!(v)` to call new helper `encode_values/1`
- Added `encode_values/1` helper function (lines 74-89) that:
  - Uses `Enum.reduce_while` to encode all map values
  - Returns `{:ok, values_map}` on success
  - Returns `:error` if ANY value fails to encode (exotic types like tuples)
  - Folds encode failures into the same `:error` path as malformed YAML
- Updated docstring to reflect non-raising behavior

### Tests (`test/engram/notes/frontmatter_test.exs`)
Added three new test cases:
1. **nested map value**: verifies JSON encoding of nested maps and order exclusion of nested keys
2. **inline colon in value**: verifies regex correctly extracts key despite colon in value
3. **bare list**: verifies rejection of non-map YAML (YamlElixir returns list, triggers `is_map/1` guard)

## Test Results
```
Running ExUnit with seed: 262008, max_cases: 20
Excluding tags: [:qdrant_integration, :cluster, :integration]

.............
Finished in 0.3 seconds (0.3s async, 0.00s sync)
13 tests, 0 failures
```

All existing tests continue to pass. No changes to existing test behavior.

## Command
```bash
cd /home/open-claw/documents/code-projects/engram/.worktrees/feat-crdt-fm-backend && \
mix format lib/engram/notes/frontmatter.ex test/engram/notes/frontmatter_test.exs && \
mix test test/engram/notes/frontmatter_test.exs
```

---

## Critical Review Fix: encode_values/1 error match arm

### Bug
The `reduce_while` halt arm was `:error -> {:halt, :error}`. `Jason.encode/1` never returns
the bare atom `:error` -- it returns `{:ok, binary}` or `{:error, %Jason.EncodeError{}}`.
The Elixir compiler confirmed this with a "clause will never match" typing violation warning.
The original crash risk (unencodable value raises `CaseClauseError`) remained live.

### Fix
Changed the halt arm from `:error -> {:halt, :error}` to `{:error, _} -> {:halt, :error}` to
match Jason's actual return shape. Also changed `encode_values/1` from `defp` to a public
`@doc false` function so the encode-failure branch can be directly unit-tested.

### Experiment: .nan / .inf investigation
Ran `YamlElixir.read_from_string("x: .nan\n")` and `.inf` / `-.inf` in `mix run --no-start`:

```
nan:     {:ok, %{"x" => :nan}}
inf:     {:ok, %{"x" => :"+inf"}}
neg-inf: {:ok, %{"x" => :"-inf"}}
```

`Jason.encode(:nan)` returns `{:ok, "\"nan\""}` -- atoms encode as strings. So YAML special
floats do NOT yield an unencodable term in this YamlElixir version.

### Test approach: direct encode_values/1 unit test via tuple
Since no real YAML value triggers a Jason encode error (atoms, lists, maps, numbers all
encode fine), added a direct `encode_values/1` test with a tuple value:

```elixir
assert Frontmatter.encode_values(%{"key" => {:not, :encodable}}) == :error
```

`Jason.encode({:not, :encodable})` returns `{:error, %Protocol.UndefinedError{}}`, which
now hits the corrected `{:error, _}` arm and halts with `:error` -- previously the bare
`:error` arm was a dead clause and the `case` on `Jason.encode/1` would have crashed with
`CaseClauseError`.

### RED evidence
The new test `encode_values/1 returns :error when a value is unencodable` FAILS without the
match-arm fix because the old `:error ->` arm is unreachable -- the `case` on
`Jason.encode({:not, :encodable})` gets `{:error, %Protocol.UndefinedError{}}` and raises
`CaseClauseError` instead of halting with `:error`, causing the test to crash rather than
assert `:error`.

### Final test run
```
Running ExUnit with seed: 224820, max_cases: 20
Excluding tags: [:qdrant_integration, :cluster, :integration]

...............
Finished in 0.2 seconds (0.2s async, 0.00s sync)
15 tests, 0 failures
```

15 tests (was 13), 0 failures. `mix compile` clean with no warnings.
