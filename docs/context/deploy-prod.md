# Deploy to AWS prod

_Last verified: 2026-06-18_

When to read this: shipping code to `app.engram.page`, rolling back a bad deploy, or debugging the deploy pipeline.

## How it works (GitOps)

Two-stage pipeline. Image build lives in this repo; image-tag selection lives in [engram-infra](https://github.com/engram-app/engram-infra). **The live image tag is reconcilable from git** — `var.engram_image_tag` in `engram-infra/main/envs/prod/variables.tf` is the source of truth.

1. **`build-and-publish-image` job in `verify.yml`** (this repo) — runs on every push to `main` (the former standalone `build-ecr.yml`, since folded into `verify.yml`). Builds the Docker image and pushes to ECR tagged `sha-<7>`. The image sits in ECR; **nothing rolls.**

2. **`deploy-prod.yml`** (this repo) — runs only when a `release-v*` git tag is pushed. Opens a PR in engram-infra rewriting `engram_image_tag` default to the `sha-<7>` of the tagged commit, enables auto-merge.

3. **engram-infra `terraform (prod)`** (engram-infra `.github/workflows/ci.yml`, `matrix: env: [staging, prod]`) — runs `terraform apply -auto-approve` on push to main. The new image tag flows into `aws_ecs_task_definition.engram`; a new revision is registered; `aws_ecs_service.engram` rolls onto it.

The OIDC build role (`engram-saas-prod-ecr-push`) trusts `refs/heads/main` + `refs/tags/v*` only — build can never accidentally roll. The deploy workflow no longer assumes any AWS role: it only opens a cross-repo PR via the `engram-infra-tf` GitHub App.

## Release recipe

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

The deploy workflow takes ~30 seconds to open the engram-infra PR. End-to-end (PR open → auto-merge after CI → `terraform apply` → service stable) is typically ~5-8 min depending on engram-infra CI latency.

Watch the chain:

1. **engram** Actions tab → `Deploy prod` → link to bot PR in step summary
2. **engram-infra** PR → CI greenlights → auto-merge fires
3. **engram-infra** Actions tab → `terraform (prod)` → apply log
4. **AWS** → `aws ecs describe-services` shows new task def revision

## Rollback recipe

Rollback is a forward-roll: push a new release tag pointing at the older commit. Same workflow, no special path.

```bash
# Find the last good commit
GOOD_SHA=abc1234

git tag release-v0.5.235 $GOOD_SHA
git push origin release-v0.5.235
```

The workflow opens an engram-infra PR bumping the var to that older `sha-<7>`. On merge, TF registers a fresh revision pinning the old image and the service rolls back. Task def history in ECS becomes the deploy log — `aws ecs list-task-definitions --family-prefix engram-saas-prod` shows every revision in order.

## Inspect deploy state

```bash
# Active task definition + image
aws ecs describe-services --cluster engram-prod --services engram-saas-prod \
  --query 'services[0].{taskDef:taskDefinition,running:runningCount,desired:desiredCount}'

# Image of the active task def
aws ecs describe-task-definition --task-definition engram-saas-prod \
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
- **Bot PR opens but doesn't auto-merge** — engram-infra CI failing (typically tflint or terraform plan). Open the PR, read the failing check, fix root cause in engram-infra. The bot will reuse the `bot/bump-engram-prod` branch on the next release tag.
- **`terraform apply` on engram-infra fails on `ResourceNotFoundException`** — `sha-<7>` image isn't in ECR. The `build-and-publish-image` job in `verify.yml` for that commit hasn't finished (or never ran). Confirm with `aws ecr describe-images`; rerun the `verify.yml` run (or its `build-and-publish-image` job) if needed.
- **Service crash-loops after deploy** — task running but health checks fail. Check CloudWatch Logs `/ecs/engram-saas-prod`, then forward-roll to the last-known-good `sha-<7>` via a new release tag.
- **App token mint step 403s** — `engram-infra-tf` App permissions changed. Required: `contents: read & write` + `pull-requests: read & write` on engram-infra. Adjust at https://github.com/organizations/engram-app/settings/apps/engram-infra-tf.

## Break-glass: manual AWS deploy

The GitOps path is the only sanctioned route. If engram-infra CI is wedged AND a deploy must ship NOW, an operator with prod admin credentials (Roles Anywhere break-glass — see `operator-cheatsheet.md` in engram-infra) can `aws ecs register-task-definition` + `update-service` directly. After the incident, **immediately** open an engram-infra PR bumping `engram_image_tag` to match what's live, otherwise the next routine `terraform apply` reverts the service.

The dedicated `engram-saas-prod-ecs-deploy` IAM role was removed when the workflow migrated to GitOps (engram-infra PR — TODO). No CI workflow needs ECS-write OIDC anymore.

## Why GitOps (not imperative)

The previous shape called `aws ecs register-task-definition` + `update-service` directly from this workflow. That stored the live image tag only in ECS state, never in git, which:

1. **Broke GitOps.** Desired state must be in git.
2. **Caused real TF drift.** `aws_ecs_service.engram` has `lifecycle.ignore_changes = [desired_count]` only — not `task_definition`. The next routine `tf apply` on engram-infra would have reverted the service to revision 1 (the TF-managed task def pointing at the old default).
3. **Was asymmetric with staging.** Staging-fastraid already runs the var-bump-PR pattern via engram-infra's `tf-apply` daemon. Prod now mirrors it.

## Why tag-gated (not merge-to-deploy)

Pre-revenue, merge-to-deploy is fine. Post-launch, every PR shipping immediately creates pressure: tests pass means deploy, no human gate, no batch-windowing. Tag-gated lets the operator (a) batch multiple merges into one release, (b) hold deploys during incident windows, (c) audit exactly what shipped when via `git tag --list 'release-v*'`. The cost is one extra step per release (`git tag && git push`) — worth it for a paid product.
