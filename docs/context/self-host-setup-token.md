# Context Doc: Self-host first-run setup token

_Added 2026-11-05._

## The hole it closes

On a self-host instance (`AUTH_PROVIDER=local`), the first successful
`POST /api/auth/register` becomes the instance admin. That window stays open
until someone claims it (`Engram.Instance.bootstrap_pending?/0`). Before this
change any unauthenticated request could claim it, so a freshly deployed,
internet-reachable instance belonged to whoever found it first.
`GET /api/auth/bootstrap` also tells a scanner which instances are still
unclaimed. Hiding that flag would not help on its own: the register endpoint was
the real hole. SaaS (Clerk) never reaches this code (`RequireLocalAuth` returns 404).

## How it works (`Engram.Instance.SetupToken`)

- **Mint on boot.** A one-shot child in `Engram.Application` (`setup_token_child/0`,
  after `Engram.Repo`) calls `SetupToken.boot/0`. With local auth and bootstrap
  pending, it creates a random 32-char token and stores only its SHA-256 in the
  `instance_setup_token` singleton row. It prints the raw token on one `:info`
  `:boot` log line. Every boot rotates the token, so the newest log line holds
  the valid one. Once the admin exists, boot deletes any leftover row.
- **Required by the claim.** While bootstrap is pending,
  `LocalAuthController.check_registration_allowed/1` needs `setup_token`.
  A missing token gets 403 `setup_token_required`, and a wrong one gets 403
  `setup_token_invalid`. The check trims whitespace and compares in constant time.
- **Burned by the claim.** `Accounts.create_user_with_password/2` deletes the row
  in the same advisory-locked transaction that creates the admin and stamps
  `bootstrap_completed_at`. After that, registration mode applies as usual, and
  the token bypasses nothing.
- **Fails closed.** If there is no row (the boot hook failed, or the table is
  missing), every claim is refused until a boot succeeds. The boot hook rescues
  its own errors and logs a warning, so it never stops the node.

Why it gets its own table and not a column on `instance_settings`: an
`instance_settings` row created before the claim would bake in a
`registration_mode` and freeze `ENGRAM_DEFAULT_REGISTRATION_MODE`. The census
table `instance_telemetry` is separate for the same reason.

## Logging rule exception

The raw token is in the boot line's **message string** on purpose. That line is
the only place it appears. It never travels as metadata, and nothing else logs
it. When the token comes from `ENGRAM_SETUP_TOKEN`, the boot line names the
variable but never prints its value. Do not add the token to any other log line
or error response.

## `ENGRAM_SETUP_TOKEN` (CI, e2e, local dev)

This variable sets a fixed token in place of the random one, so automation can
claim the admin without reading logs. It only counts while bootstrap is pending.

| Where | Value |
|---|---|
| `ci/compose.local.yml`, Playwright job in `verify.yml`, `frontend/playwright.config.ts` local backend | `e2e-setup-token` |
| e2e senders: `e2e/helpers/auth_provider.py` `SETUP_TOKEN`, `frontend/e2e/support/api.ts` `SETUP_TOKEN`, `e2e/headless/run.ts` | env, else `e2e-setup-token` |
| `.env.local-selfhost.example` (`make dev-selfhost`, workspace `make dev-local`) | unset, commented out: local dev gets the real random-token flow |

Local dev deliberately leaves it unset so the team keeps seeing what a
self-hoster sees. To pin it, uncomment the line in your own
`.env.local-selfhost` (`make dev-selfhost`). Or pass it inline:
`ENGRAM_SETUP_TOKEN=... make dev-local`. The workspace script sources the
example file without clearing your shell value, so an inline value still applies.

Every e2e register call sends the token, because any of them may be the first
signup on a fresh stack. After the claim the backend ignores it.

Multi-node self-host: each booting node rotates the token, so only the token
from the most recent boot works. Set `ENGRAM_SETUP_TOKEN` if that gets in the way.

## Tests

- `test/engram_web/controllers/local_auth_controller_test.exs`, "first-run setup
  token": no token, wrong token, never minted, valid, and burned/not reusable.
  Its top-level `setup` mints a known token through `SetupToken.mint/1`, because
  boot does not run the mint under test (`:setup_token_on_boot` is false in
  `config/test.exs`).
- `test/engram/instance/setup_token_test.exs`: boot mint, rotation, hash-only
  storage, env token not logged, no-op under Clerk, and the burn in the claim
  transaction.
- Both were checked against mutations. With the controller guard removed, the
  three refusal tests fail. With the burn removed, both burn tests fail.
