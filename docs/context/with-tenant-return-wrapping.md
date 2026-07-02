# `Repo.with_tenant/2` return-wrapping gotcha

_Last verified: 2026-07-01 (PR #846, CRDT hardening wave)_

## Status

Live — three implementers hit this on the same day. The rule below prevents it from recurring.

## The rule

**Funs passed to `with_tenant` must return bare values.** Match `{:ok, value}` at the call site, not inside the fun:

```elixir
# CORRECT — fun returns bare value; caller unwraps the {:ok, _}
{:ok, count} = Repo.with_tenant(user_id, fn ->
  Repo.aggregate(CrdtUpdateLog, :count)
end)

# WRONG — fun returns {:ok, x}; caller receives {:ok, {:ok, x}}
{:ok, count} = Repo.with_tenant(user_id, fn ->
  {:ok, Repo.aggregate(CrdtUpdateLog, :count)}  # <-- double-wraps
end)
```

## Why

`Repo.with_tenant/2` calls `Ecto.Repo.transaction/1` internally. `transaction/1` wraps the fun's return in `{:ok, _}` on success. A fun that itself returns `{:ok, x}` produces `{:ok, {:ok, x}}`.

The re-entrant fast path (same tenant, already in a transaction — `lib/engram/repo.ex:55`) also wraps with `{:ok, fun.()}`, so the shape is consistent either way. There is no path through `with_tenant` where the caller gets an unwrapped value.

## The three instances from 2026-07-01 (PR #846)

### 1. Test assertion failure

A test asserted `remaining == 1` after a `with_tenant` call. The fun returned `{:ok, remaining}` (leftover from an earlier refactor). Actual left-hand side was `{:ok, 1}`, not `1`. Failure message: `left: {:ok, 1}`. Looked like an off-by-one at first glance.

### 2. Latent prod bug — embed-skip gate always-true

```elixir
# In a checkpoint handler (simplified):
{:ok, prev_hash} = Repo.with_tenant(user_id, fn ->
  prev = get_content_hash(note_id)
  {:ok, prev}   # <-- bug: fun wraps the hash
end)
# prev_hash is now {:ok, "abc123"}, not "abc123"

if prev_hash != content_hash do   # always true — tuple != binary
  enqueue_embed(note_id)          # every checkpoint triggered an embed job
end
```

Oban's uniqueness window absorbed most of the duplicate jobs so no observable spike reached Voyage AI, but every checkpoint was enqueuing work it should have skipped. Caught in code review during PR #846.

### 3. CRDT doc test double-match

A `crdt_doc_test` helper pattern-matched `{:ok, doc}` against `Repo.with_tenant(...)` where the fun returned `{:ok, doc}`. Test passed at the match site (the outer `{:ok, _}` consumed silently), but downstream assertions on `doc` failed because `doc` was `{:ok, actual_doc}`. Pattern looked correct locally, error appeared two assertions later.

## Audit hint

To find existing double-wrap sites:

```bash
grep -n "with_tenant" lib/**/*.ex test/**/*.ex \
  | grep -v "^Binary" \
  | xargs grep -l "with_tenant" \
  | xargs grep -A10 "with_tenant" \
  | grep "{:ok,"
```

Or more targeted: search for `with_tenant` call sites whose fun body ends in `{:ok,` before the closing `end`:

```bash
grep -rn "with_tenant" lib/ test/ --include="*.ex" -A 5 | grep "{:ok,"
```

Review each hit: if the `{:ok,` is inside the fun (not the call-site match), it is a candidate double-wrap.

## If the fun genuinely must return a tuple

If the fun's return is already a tagged tuple for its own semantic reasons (e.g. an inner `:ok`/`:error` path), leave the fun as-is and match loudly at the call site:

```elixir
# Fun returns {:ok, x} | {:error, reason} for its own logic —
# with_tenant wraps the whole thing in {:ok, _}
{:ok, inner_result} = Repo.with_tenant(user_id, fn ->
  case do_thing() do
    {:ok, v} -> {:ok, v}
    {:error, r} -> {:error, r}
  end
end)
# inner_result is {:ok, v} or {:error, r} — handle it next
case inner_result do
  {:ok, v} -> ...
  {:error, r} -> ...
end
```

Comment loudly when doing this so the next reader does not flatten it.

## Dead ends

- **Adding `{:ok, result} = transaction(...)` to the fun** to "fix" a match failure — this wraps again. The fix is always at the fun boundary: return bare values from the fun.
- **Using pattern `{:ok, {:ok, x}} = Repo.with_tenant(...)`** to make a test pass — correct structurally but silently accepts the double-wrap pattern and leaves a trap for the next caller that expects a single wrap.

## References

- `lib/engram/repo.ex` — `with_tenant/2` + `run_with_tenant/1`; re-entrant fast path at line 55
- PR #846 — CRDT hardening wave where all three instances surfaced the same day
