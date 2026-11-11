# Context Doc: Boot-time migrations and limits shared by one network

_Last verified: 2026-11-10_

## Status

Working. The boot crash in release 0.79.0 is fixed by #2545 (issue #2543). The
shared-network throttling is fixed by #2542.

## What This Is

Lessons from one release session: how a data migration can crash every boot
without a slow query, what such a migration must do to be safe, and how to set
and test rate limits when many people share one network address.

## Environment

SaaS prod on ECS Fargate behind an ALB, RDS Postgres under FORCE RLS. The
migration rules apply to self-host too, since every install runs the same
migrations at boot.

## Key Commands / Patterns

### Data migrations that run at boot

- **Hold no connection across a loop.** Give each unit of work its own short
  transaction. `20261107120000_note_bodies_complete_split_migrate.exs` is the
  reference: tenanted probes in batches of 200 users, then one transaction per
  id window with `lock_timeout` set inside it.
- **If a block really must pin one connection, pass a timeout to the checkout:**
  `repo.checkout(fn -> ... end, timeout: 120_000)`, as
  `20261107130100` does around its `VALIDATE CONSTRAINT`. This is for a short,
  bounded list of statements. Never use a longer timeout or `timeout: :infinity`
  to make a loop fit; split the loop instead (`migrations-playbook.md`).
- **Never "log and continue" past a user that failed for a reason a later boot
  can clear**, such as lock contention. A migration that finishes is recorded
  and never runs again, so a skipped user is a permanent gap once the source
  columns drop. Retry, make a final pass over the skipped users, then raise with
  the count. The migration stays unrecorded and the next boot resumes. A
  condition no retry would change (in `20261107120000`, a note still unreadable
  after repair) is the exception: log a warning and finish, because raising
  would block every boot for good.
- **Only trust a "nothing to do" pre-check on a connection that can see every
  tenant**: a superuser or `rolbypassrls` role, or a session that has actually
  run `SET LOCAL ROLE engram_maintenance`, where that role has `SELECT` and a
  `maintenance_all` policy on every table the query reads. Being allowed to
  switch is not enough: without the switch the query still sees nothing. Check
  that first (`@visibility` in `20261107120000`), and otherwise go per user
  inside each tenant's context.
- **Budget about 60 to 80s for migrations, not 120s.** The web service's health
  check grace is 120s (`health_check_grace_period_seconds`), but migrations run
  in `entrypoint.sh` before the app listens, so they spend the same clock as
  BEAM start and the health checks that follow. The worker has no load balancer
  and no grace, only the container health check.

### Rate limits when people share a network

- Per-IP limits punish everyone behind one NAT. A strict 10/min per IP on
  `/oauth/authorize` throttled a group on one shared network signing up
  together.
- Key on a secret credential or the user where one exists, and keep a high
  per-IP ceiling for floods. A public identifier is different: a CIMD
  `client_id` is shared by every user of a vendor, so key it per credential per
  IP (`:client`). Key on the credential alone (`:secret`) only for an
  unguessable value, or anyone can exhaust that bucket for everybody.
  `EngramWeb.KeyedRateLimit` holds the buckets and the ceiling;
  `EngramWeb.Plugs.OAuthRateLimit` and `EngramWeb.Plugs.DeviceAuthRateLimit`
  hold the per-route policy.
- A route with no credential to key on (`/oauth/authorize`) stays per IP, with
  the limit raised to a flood ceiling (300/min).

### Testing a per-minute limiter

The Hammer window is fixed and epoch-aligned (`div(now, scale)`). Start the
burst just after the minute turns. In tests, `reset_buckets!` in
`lib/engram_web/rate_limiter.ex` waits past the next 10s edge only when less
than 1s remains before it, so keep a burst under 1s.

## Failed Approaches / Dead Ends

- **One `repo.checkout` around a walk of all users.** It crashed every boot of
  0.79.0 at 1,637 users. Staging likely passed because it has fewer users (not
  verified).
- **Raising statement timeouts inside the checkout.** They are ignored for this
  purpose: the checkout's own timeout bounds the whole block.
- **A plain untenanted `EXISTS` as the pre-check.** For a role that does not
  bypass FORCE RLS it returns false even while rows need work, which would skip
  all of it. A superuser gets true, so dev and CI hide the bug. The same trap
  for writes is in `migrations-force-rls-data-dml.md`.
- **A limiter probe that straddled a minute boundary.** The first prod probe in
  this session did this. The burst split across two windows and proved nothing.

## Gotchas

- `repo.checkout(fn -> ... end)` with no timeout inherits DBConnection's 15s for
  the WHOLE block. There is no slow query to find. The log line is:
  `client ... (Task.Supervised) timed out because it queued and checked out the connection for longer than 15000ms`
- Prod's migrator passes neither visibility check, so prod takes the per-user
  tenanted probe: about 2 statements per user (3,303 at 1,637 users, counted on
  a throwaway database). On prod the probe took 12.7s and found no user needing
  work, so no walk ran. That is within the migration budget, but it grows with
  the user count.
- `ai_searches_per_day` is a fixed window that resets at 00:00 UTC, not a
  rolling 24 hours. A user can spend the budget on both sides of midnight UTC.
  See `rate-limiter-architecture.md` for why a node restart also resets it.
- A release containing any `feat:` commit bumps the minor version under
  release-please, so a planned 0.79.2 shipped as 0.80.0. Anything that refers to
  a planned release by number should expect that.

## References

- `priv/repo/migrations/20261107120000_note_bodies_complete_split_migrate.exs`
- `priv/repo/migrations/20261107130100*` (explicit checkout timeout)
- `entrypoint.sh` (migrations before `exec` of the release)
- `lib/engram_web/keyed_rate_limit.ex`, `lib/engram_web/plugs/oauth_rate_limit.ex`,
  `lib/engram_web/plugs/device_auth_rate_limit.ex`
- `docs/context/data-migrations-ledger.md`, `docs/context/migrations-playbook.md`
- `docs/context/migrations-force-rls-data-dml.md`, `docs/context/maintenance-db-role.md`
- `docs/context/rate-limiter-architecture.md`
- #2543, #2545, #2542
