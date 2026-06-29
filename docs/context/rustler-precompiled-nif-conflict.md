# Context Doc: rustler_precompiled NIF version conflict (mjml vs lingua)

_Last verified: 2026-06-29_

## Status
Working — resolved via a single Mix override.

## What This Is
engram pulls in multiple Rust NIFs through `rustler_precompiled`. Two of them
pin **incompatible** `rustler_precompiled` requirements, which makes
`mix deps.get` unsatisfiable until we force a single version with an override.

## The Conflict
`rustler_precompiled` consumers (see `mix.lock`):

| Dep | Purpose | `rustler_precompiled` requirement |
|-----|---------|-----------------------------------|
| `mjml` (6.0.0) | Email templating (MJML → HTML, mrml NIF) | `~> 0.9.0` (i.e. `>= 0.9.0 and < 0.10.0`) |
| `lingua` (0.3.6) | Keyword-leg language detection | `~> 0.8.4` (i.e. `>= 0.8.4 and < 0.9.0`) |
| `y_ex` (0.10.5) | CRDT (yrs NIF) | `>= 0.6.0` |

`mjml` needs `>= 0.9.0`, `lingua` caps at `< 0.9.0` → **no version satisfies
both**. `mix deps.get` fails to resolve.

## Resolution
Add to `mix.exs` deps:

```elixir
{:rustler_precompiled, "~> 0.9.0", override: true},
```

This forces `rustler_precompiled 0.9.0` for all three deps:
- `mjml` and `y_ex` are satisfied natively.
- `lingua`'s `~> 0.8.4` pin is **conservative, not a real ceiling** — lingua
  compiles and runs fine against `rustler_precompiled 0.9.0`. The override
  resolves the deadlock and lingua works despite its declared pin.

No Dockerfile change and no Rust toolchain are needed — both NIFs download
their precompiled `.so` at `deps.get` time.

## Verified
Built in the prod builder image
(`hexpm/elixir:1.17.3-erlang-27.1.2-debian-bookworm-...`, OTP 27, **no Rust
toolchain installed**):
- All three deps resolve with the override.
- Both NIFs download precompiled: `mjml` (nif-2.16) and `lingua` (nif-2.15),
  both `x86_64-unknown-linux-gnu`.
- Both load + run at runtime: lingua detects language and mjml renders
  (`{{:ok, :german}, :ok}`).

### NIF version forward-compat
A `nif-2.15` precompiled `.so` loads fine on OTP 27 (ERTS NIF 2.17).
`rustler_precompiled` selects the artifact by **target triple + NIF version**
with backward compatibility, so an older-NIF artifact runs on a newer ERTS.

## Gotchas
- **The "does this dependency work?" gate must run against the project's REAL
  full dependency tree** (ideally the prod builder image), not an isolated
  probe project. An isolated probe of `lingua` alone passed and gave a false
  GO — the conflict only appears alongside `mjml`. lingua works solo; lingua +
  mjml does not without the override.
- The override silently masks lingua's declared pin. If lingua ever breaks
  against a future `rustler_precompiled`, this is the first place to look.

## References
- `mix.exs` (deps: `:mjml`, `:y_ex`, `:lingua`, `:rustler_precompiled` override)
- `mix.lock` (locked `rustler_precompiled` 0.9.0 + per-dep requirements)
