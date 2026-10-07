# Deploy to AWS prod

_Last verified: 2026-10-03_

When to read this: shipping code to `app.engram.page`, rolling back a bad deploy, or debugging the deploy pipeline.

## How it works (GitOps)

Two-stage pipeline. Image build lives in this repo; image-tag selection lives in [engram-infra](https://github.com/engram-app/engram-infra). **The live image tag is reconcilable from git** — `var.engram_image_tag` in `engram-infra/main/envs/prod/variables.tf` is the source of truth.

1. **`build-and-publish-image` job in `verify.yml`** (this repo) — runs on every push to `main` (the former standalone `build-ecr.yml`, since folded into `verify.yml`). Builds the Docker image and pushes to ECR tagged `sha-<7>`. The image sits in ECR; **nothing rolls.**

2. **`deploy-prod.yml`** (this repo), runs only when a `release-v*` git tag is pushed. Job `release-e2e-gate` first dispatches `verify.yml` with `force_full` on the tagged commit and blocks the deploy unless the full-Obsidian e2e jobs pass (emergency override: an annotated tag whose message contains `[skip-release-e2e]`). Job `open-infra-pr` then opens a PR in engram-infra rewriting `engram_image_tag` default to the `sha-<7>` of the tagged commit, and **stops there, it does NOT merge and does NOT enable auto-merge** (#1155; see "Promotion gate" below). Prod does not move until a human merges that PR. The workflow prints the exact command in its step summary.

3. **engram-infra `terraform (prod)`** (engram-infra `.github/workflows/ci.yml`, `matrix: env: [staging, prod]`), runs `terraform apply -auto-approve` on push to main. The new image tag flows into `aws_ecs_task_definition.engram`, which is `for_each` over the `web` and `worker` node roles. Both services roll: `engram-saas-prod` (web) and `engram-worker-prod` (Oban worker). One tag, two task-def revisions.

The OIDC build role (`engram-saas-prod-ecr-push`) trusts `refs/heads/main` + `refs/tags/v*` only — build can never accidentally roll. The deploy workflow no longer assumes any AWS role: it only opens a cross-repo PR via the `engram-infra-tf` GitHub App.

## Release recipe

**The normal path is automatic — you do not tag by hand.** Merging the
release-please PR makes release-please.yml push `release-v<version>` itself, so
`deploy-prod.yml` fires without anyone running the commands below. A hand push of that tag is rejected as
`already exists`; that is expected.

That is also why deploy-prod cannot assume the image already exists: the tag is
pushed by the *same* main push that starts main CI, and `build-and-publish-image`
runs last in that CI. `open-infra-pr` therefore waits for that job to succeed
before writing the pin (see "Failure modes"). The manual recipe below is for a
rollback or a re-release of an older commit.

```bash
# Pull latest main, confirm CI is green, confirm the image is in ECR
git checkout main && git pull
SHA=$(git rev-parse --short=7 HEAD)
aws ecr describe-images --repository-name engram-saas-prod \
  --image-ids imageTag=sha-$SHA \
  --query 'imageDetails[0].imagePushedAt' --output text

# Tag + push. Convention: bump the patch from the previous release.
git tag release-v0.5.234
git push origin release-v0.5.234
```

The deploy workflow takes ~30 seconds to open the engram-infra PR. **Prod does not
move until you promote** (see below). Once promoted, `terraform apply` → service
stable is typically ~5-8 min depending on engram-infra CI latency.

Watch the chain:

1. **engram** Actions tab → `Deploy prod` → link to bot PR in step summary
2. **staging** → verify it carries this release (below)
3. **engram-infra** PR → you merge it
4. **engram-infra** Actions tab → `terraform (prod)` → apply log
5. **AWS** → `aws ecs describe-services` shows new task def revision

## Promotion gate (staging first)

Merging the release-please PR rolls staging and prod off the same event. Until
engram-app/Engram#1155 the prod bump PR was auto-merged, so prod moved as soon as
its checks went green — before anyone could look at staging. The PR is now opened
and left alone.

Staging is rolling to the same release automatically. Before promoting, check it
carries the release and is actually healthy:

```bash
# 1. staging is serving the expected version
curl -s https://staging.engram.page/api/health | jq .

# 2. migrations ran clean and the container booted (not crash-looping)
#    -> engram-infra Actions tab, `terraform (staging)` apply log

# 3. a real client handshake works, not just HTTP 200
#    -> docs/context/oauth-discovery-urls-behind-edge-tls.md
```

Then promote. The `Deploy prod` job summary prints this exact line with the PR
number filled in:

```bash
gh pr merge --squash --repo engram-app/engram-infra <PR_NUMBER>
```

**Why not required reviewers?** A GitHub Environment protection rule would also
gate this, but it puts a reviewer in the path of an incident rollback. This gate
is one command by the operator, so a forward-roll is not slowed — see the
rollback recipe.

## Rollback recipe

Rollback is a forward-roll: push a new release tag pointing at the older commit. Same workflow, no special path.

```bash
# Find the last good commit
GOOD_SHA=abc1234

git tag release-v0.5.235 $GOOD_SHA
git push origin release-v0.5.235
```

The workflow opens an engram-infra PR bumping the var to that older `sha-<7>`. Merge it immediately — the promotion gate above is a manual merge, not a review requirement, so nothing queues behind another person during an incident. On merge, TF registers a fresh revision pinning the old image and the service rolls back. Task def history in ECS becomes the deploy log — `aws ecs list-task-definitions --family-prefix engram-saas-prod` shows every revision in order.

## Inspect deploy state

```bash
# Active task definition + image
aws ecs describe-services --cluster engram-prod --services engram-saas-prod \
  --query 'services[0].{taskDef:taskDefinition,running:runningCount,desired:desiredCount}'

# Image of the active task def
aws ecs describe-task-definition --task-definition engram-saas-prod \
  --query 'taskDefinition.containerDefinitions[0].image' --output text

# Worker tier (same commands, family engram-worker-prod)
aws ecs describe-task-definition --task-definition engram-worker-prod \
  --query 'taskDefinition.containerDefinitions[0].image' --output text

# Recent revisions (most recent first)
aws ecs list-task-definitions --family-prefix engram-saas-prod --sort DESC --max-items 10

# Image inventory in ECR
aws ecr describe-images --repository-name engram-saas-prod \
  --query 'sort_by(imageDetails,&imagePushedAt)[-10:].[imageTags[0],imagePushedAt]' \
  --output table

# Current source of truth for live image:
gh api repos/engram-app/engram-infra/contents/main/envs/prod/variables.tf \
  --jq '.content' | base64 -d | grep -A2 engram_image_tag
```

Operator AWS profile is `engram-infra-operator` (read-only — `operator-cheatsheet.md` in engram-infra).

## Failure modes

- **`deploy-prod.yml` step "Rewrite engram_image_tag default" fails** — regex regression. Check `main/envs/prod/variables.tf` shape in engram-infra; the workflow expects exactly one `variable "engram_image_tag"` block with a `default = "..."` line.
- **Bot PR checks are red**: engram-infra CI failing (typically tflint or terraform plan). Read the failing check, fix root cause in engram-infra. The bot reuses the `bot/bump-engram-prod` branch on the next release tag.
- **`terraform (prod)` fails on `reading ECR Images: couldn't find resource`**: the `sha-<7>` image isn't in ECR, so `data.aws_ecr_image.engram_pin_check` (ecs.tf) and `engram_image_pin` (ecr.tf) fail the plan. This used to happen on *every* release: the tag is pushed the instant the release commit lands on main, and `build-and-publish-image` finishes ~20 min later, while the release e2e gate only absorbed ~14 min, `release-v0.10.0` and `release-v0.11.0` both died this way. `open-infra-pr` now waits for that job before writing the pin, so a fresh occurrence means the wait timed out (>30 min) or the job genuinely failed. Confirm with `aws ecr describe-images`, then re-run the failed `terraform (prod)` check, or, if the bot PR has gone behind main, `gh pr update-branch <n>` in engram-infra to re-run the checks, then merge it.
- **Service crash-loops after deploy** — task running but health checks fail. Check CloudWatch Logs `/ecs/engram-saas-prod`, then forward-roll to the last-known-good `sha-<7>` via a new release tag.
- **App token mint step 403s** — `engram-infra-tf` App permissions changed. Required: `contents: read & write` + `pull-requests: read & write` on engram-infra. Adjust at https://github.com/organizations/engram-app/settings/apps/engram-infra-tf.

## Break-glass: manual AWS deploy

The GitOps path is the only sanctioned route. If engram-infra CI is wedged AND a deploy must ship NOW, an operator with prod admin credentials (Roles Anywhere break-glass — see `operator-cheatsheet.md` in engram-infra) can `aws ecs register-task-definition` + `update-service` directly. After the incident, **immediately** open an engram-infra PR bumping `engram_image_tag` to match what's live, otherwise the next routine `terraform apply` reverts the service.

## Verifying prod moved

A green `deploy-prod.yml` means an engram-infra PR was opened. A green `terraform apply` means UpdateService was called: no ECS service in engram-infra `main/` sets `wait_for_steady_state`, so apply returns before the rollout finishes.

- **Without AWS creds**, query Grafana Prometheus: `count by (role) (up{job="prometheus.scrape.engram_app"})`. A completed rolling replacement doubles each role's target count, then settles (observed `web 2 → 4 → 2`, `worker 1 → 2 → 1`). The worker doubling is what proves the Oban cron tier rolled, not just web; split `by (role)`, a total hides it.
- **A frozen Loki frontier at night is not a logging outage.** Prod logs only on activity, so after a deploy's burst the newest line can stop for an hour or more. Before calling logs dead, run `query_loki_stats` over a comparable pre-deploy quiet window (same zeroes = normal), confirm the `up{...}` query above is current, and `curl -s https://api.engram.page/api/health` (reports `version` and `build_sha`).

## `create-release-notes` 403 "Resource not accessible by integration"

`GITHUB_TOKEN` with `contents: write` is not always enough to create a
Release. For some target commits the Releases API accepts only
`contents=write,workflows=write` (read it in the `X-Accepted-Github-Permissions`
response header via `gh api -i`), and a workflow token can never hold
`workflows`. release-v0.43.0 hit this on 2026-10-07: same token, command and
settings as 0.42.0, yet 403 on its release commit and 201 on 0.42.0's. Which
commits trip it is GitHub's call; do not guess from the range. The job creates
the Release with the Engram App installation token (#1894). If it recurs, one
probe shows the accepted permissions:
`gh api -i -X POST repos/<repo>/releases -f tag_name=probe -f target_commitish=<sha> -F draft=true`
(then delete the draft).
