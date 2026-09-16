# Prod release verification — what "success" does NOT mean

_Last verified: 2026-09-16_

When to read this: you cut a release and want to know whether prod actually
moved. Five green things along this chain each mean less than they look like.
Mechanics of the pipeline itself are in `docs/context/deploy-prod.md`; this doc
is only the verification traps.

## `git tag release-v… && git push` → `! [rejected] … (already exists)`

release-please cuts the tag itself. When its release PR merges,
`.github/workflows/release-please.yml` pushes `release-v<version>` (via the App
token, so the tag triggers `deploy-prod.yml`). By the time you think to tag by
hand, the tag is already on the remote pointing at the release commit, and your
push is correctly rejected.

The real flow: **verify the release PR's changelog, merge it, done.** Tag +
`deploy-prod.yml` fire automatically. Tag by hand only for a rollback or a
re-release of an older commit.

> The workspace `../engram-workspace/CLAUDE.md` "Quick Commands" block still
> prints the manual `git tag release-v0.5.450 <sha> && git push` recipe as if it
> were the normal path. It is not. That block is stale.

## `deploy-prod.yml` green → prod has NOT moved

Its three jobs are `release-e2e-gate` (dispatches `verify.yml` with
`force_full` on the tagged commit and waits on the full Obsidian e2e suite),
`open-infra-pr`, and `create-release-notes`. Success means **an engram-infra PR
was opened** — `chore(prod): bump engram image to sha-<7>`. Nothing rolled.

Prod moves when that PR merges and `terraform apply` runs on engram-infra main.
The paired `chore(staging-fastraid)` PR auto-merges; **the prod one does not**
(#1155 — the promotion gate). Seeing staging carry the release says nothing
about prod.

## `terraform apply` green → the rollout has NOT finished

`wait_for_steady_state` is not set on any ECS service anywhere in engram-infra
`main/`. Terraform registers the new task-def revision, calls UpdateService, and
returns immediately. Apply duration is unrelated to rollout duration.

## Verifying the rollout without AWS credentials

Query Grafana Prometheus:

```promql
count by (role) (up{job="prometheus.scrape.engram_app"})
```

A completed rolling replacement shows each role's target count double, then
settle back. Observed on 2026-09-16: `web 2 → 4 → 2`, `worker 1 → 2 → 1`.

**The worker doubling is the load-bearing half** — it proves the Oban cron tier
cycled onto the new image, not just the web tier. A web-only roll looks like
`3 → 5 → 3` in the aggregate, which is why you split `by (role)` instead of
watching one total.

Both roles roll off one variable bump even though `var.engram_image_tag` is
*described* as being for `engram-saas-prod`: the single
`image_tag = var.engram_image_tag` lookup at `main/envs/prod/ecs.tf:116`
resolves one digest, and `aws_ecs_task_definition.engram` is
`for_each = local.node_roles` (`web` + `worker`, ecs.tf:277) over that same
digest. Two services, two task-def revisions, one tag.

## A frozen Loki frontier at night is not a logging outage

Prod engram logs only on activity (healthy systems are quiet — see the logging
taxonomy in `AGENTS.md`). After a deploy's log burst ends, the newest ingested
line stops advancing, which looks exactly like ingestion death.

2026-09-16 03:00–04:40Z was a real 100-minute stretch with literally zero
entries — `query_loki_stats` returned `{"streams":0,"entries":0}`. Nothing was
broken.

Before concluding logs are dark:

1. `query_loki_stats` over a comparable **pre-deploy** quiet window. Same
   zeroes = normal quiet, not a new outage.
2. Confirm Prometheus is still current (the `up{...}` query above).
3. `curl https://api.engram.page/health`.

Metrics kept flowing and `/health` returned 200 the whole time.

## References

- `docs/context/deploy-prod.md` — the pipeline itself, promotion gate, rollback
- `.github/workflows/release-please.yml` (the `release-v*` tag push)
- `.github/workflows/deploy-prod.yml`
- engram-infra `main/envs/prod/ecs.tf`, `main/envs/prod/variables.tf`
