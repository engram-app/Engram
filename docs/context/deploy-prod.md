# Deploy to AWS prod

When to read this: shipping code to `app.engram.page`, rolling back a bad deploy, or debugging the deploy pipeline.

## How it works

Two-stage pipeline split into two GitHub Actions workflows in this repo:

1. **`build-ecr.yml`** — runs on every push to `main`. Builds the Docker image and pushes to ECR tagged `sha-<7chars>`. The image sits in ECR; **nothing rolls.**
2. **`deploy-prod.yml`** — runs only when a `release-v*` git tag is pushed. Clones the live task definition, swaps in the image for the tagged commit, registers a new revision, and `update-service` rolls the cluster.

OIDC IAM trust enforces the boundary: the build role (`engram-saas-prod-ecr-push`) trusts `refs/heads/main` + `refs/tags/v*` only; the deploy role (`engram-saas-prod-ecs-deploy`) trusts `refs/tags/release-v*` only. Build can never accidentally roll, deploy can never accidentally push an image.

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

The deploy workflow takes ~3-5 min: register task def → update-service → `wait services-stable`. Watch in the Actions tab.

## Rollback recipe

Rollback is a forward-roll to a known-good image. Same trigger mechanism — push a release tag pointing at the older commit:

```bash
# Find the last good commit (whichever sha-<7> image you want back live)
GOOD_SHA=abc1234

# Tag with a -rollback suffix for audit clarity (any release-v* matches)
git tag release-v0.5.234-rollback $GOOD_SHA
git push origin release-v0.5.234-rollback
```

The workflow registers a fresh task def revision pinning that old image and rolls the service. Task def history in ECS becomes the deploy log — `aws ecs list-task-definitions --family-prefix engram-saas-prod` shows every deploy in order.

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
```

Operator AWS profile is `engram-infra-operator` (read-only — `operator-cheatsheet.md` in engram-infra). For deploy/rollback CLI access (write), use the IAM Roles Anywhere break-glass path documented there.

## Failure modes

- **`deploy-prod.yml` step "Verify image exists in ECR" fails** — `build-ecr.yml` hasn't finished for that commit yet, or the commit was never on main. Wait for build to finish, or check the commit is reachable from `origin/main`.
- **`wait services-stable` times out (10 min)** — task is crash-looping. Check CloudWatch Logs `/ecs/engram-saas-prod`, then roll back via the rollback recipe.
- **`Register new task definition` fails with `iam:PassRole`** — the ecs_deploy role's PassRole permission is conditional on `iam:PassedToService = ecs-tasks.amazonaws.com`. If the task def's `executionRoleArn` or `taskRoleArn` references a role outside `engram-saas-prod-ecs-{execution,task}`, fix the upstream TF in engram-infra `main/envs/prod/ecs_iam.tf`.

## Why not merge-to-deploy?

Pre-revenue, merge-to-deploy is fine. Post-launch, every PR shipping immediately creates pressure: tests pass means deploy, no human gate, no batch-windowing. Tag-gated lets the operator (a) batch multiple merges into one release, (b) hold deploys during incident windows, (c) audit exactly what shipped when via `git tag --list 'release-v*'`. The cost is one extra step per release (`git tag && git push`) — worth it for a paid product.
