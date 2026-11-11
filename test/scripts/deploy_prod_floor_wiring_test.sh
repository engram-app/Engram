#!/usr/bin/env bash
# test/scripts/deploy_prod_floor_wiring_test.sh
#
# The script tests cannot see how the workflows call them. This pins the
# wiring, parsed as YAML so a reformat does not break it: the floor gate reads
# MAIN's floor and judges the tagged commit, the deploy waits on the gate, CI
# checks the floor tag, and every deploy job has a failure alert that is
# self-contained (no repo file: it must still post when the checkout failed).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)/../.."

python3 - "$ROOT/.github/workflows/deploy-prod.yml" "$ROOT/.github/workflows/verify.yml" <<'PY'
import re, sys, yaml

def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)

deploy = yaml.safe_load(open(sys.argv[1]))["jobs"]
verify = yaml.safe_load(open(sys.argv[2]))["jobs"]

def runs(job):
    return "\n".join(s.get("run", "") for s in job.get("steps", []))

gate = deploy.get("release-floor-gate") or fail("no release-floor-gate job")
if not any("checkout" in s.get("uses", "") and str((s.get("with") or {}).get("fetch-depth")) == "0" for s in gate["steps"]):
    fail("the gate does not fetch history and tags")
if "git show origin/main:priv/release_floor" not in runs(gate):
    fail("the gate does not read main's floor")
if not re.search(r'check_release_floor\.sh\s+"\$floor"\s+"\$GITHUB_SHA"', runs(gate)):
    fail("the gate does not judge the tagged commit")

needs = deploy["release-e2e-gate"].get("needs", [])
if "release-floor-gate" not in ([needs] if isinstance(needs, str) else needs):
    fail("the deploy does not wait on the floor gate")

if "check_floor_tag_on_main.sh" not in runs(verify["static-checks"]):
    fail("CI does not check the floor tag")

for name in ("release-floor-gate", "release-e2e-gate", "open-infra-pr"):
    alerts = [s for s in deploy[name]["steps"]
              if "failure()" in str(s.get("if", "")) and "DISCORD_ALERTS_WEBHOOK_URL" in str((s.get("env") or {}).get("WEBHOOK", ""))]
    if not alerts:
        fail(f"{name}: a red job does not alert")
    for s in alerts:
        run = s.get("run", "")
        if "curl" not in run or re.search(r"\b(scripts|test)/", run):
            fail(f"{name}: alert '{s.get('name')}' is not self-contained (it must post without the checkout)")
PY

echo "deploy_prod_floor_wiring: all cases passed"
