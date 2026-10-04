# `Repo.with_tenant/2` return-wrapping gotcha

_Last verified: 2026-10-03_

## The rule

**Funs passed to `with_tenant` return bare values.** `with_tenant/2` returns
`{:ok, result}`; a fun that itself returns `{:ok, x}` gives the caller
`{:ok, {:ok, x}}`.

```elixir
# CORRECT
{:ok, count} = Repo.with_tenant(user_id, fn -> Repo.aggregate(CrdtUpdateLog, :count) end)

# Or, when the tuple carries no information:
count = Repo.with_tenant!(user_id, fn -> Repo.aggregate(CrdtUpdateLog, :count) end)

# WRONG: caller receives {:ok, {:ok, n}}
{:ok, count} = Repo.with_tenant(user_id, fn -> {:ok, Repo.aggregate(CrdtUpdateLog, :count)} end)
```

## Why

`with_tenant/2` runs the fun in `Repo.transaction`, which wraps the return in
`{:ok, _}`. The re-entrant same-tenant path returns `{:ok, fun.()}` to match,
so there is no path where the caller gets an unwrapped value.
`with_tenant!/2` unwraps it for you.

The cost is silent: in PR #846 a wrapped content hash made an embed-skip gate
(`prev_hash != content_hash`) always true, so every checkpoint enqueued an
embed. A double-wrapped match can also "pass" at the call site and fail two
assertions later.

## If the fun genuinely returns a tagged tuple

Leave the fun as is, match `{:ok, inner} = Repo.with_tenant(...)`, then branch
on `inner`. Comment it so the next reader does not flatten it.

## Dead ends

- Wrapping the fun body in another `transaction(...)` to fix a match failure.
  It wraps again.
- Matching `{:ok, {:ok, x}}` to make a test pass. It accepts the double wrap
  and leaves the trap for the next caller.

## References

- `lib/engram/repo.ex`: `with_tenant/2`, `with_tenant!/2`, `run_with_tenant/2`
