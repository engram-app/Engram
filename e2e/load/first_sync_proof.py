#!/usr/bin/env python3
"""Staging proof: a 30k-note + attachments first sync survives a server kill mid-sync.

Regression proof for the 2026-10-29 prod crash loop (Engram#2306, fix PR #2308):
a bulk first sync grew the per-vault CRDT index room's update tail, every
restart re-bound the room and replayed that tail, and the replay OOM-killed the
node again (docs/context/web-oom-index-room-tail-replay-2026-10-29.md).

Three subcommands, split by where they must run:

  generate  Deterministic synthetic vault (notes + attachments) from a seed.
            Cheap at small N; the 30k corpus is ~1 GB, so CI builds it.
  load      CI (runner VM, .github/workflows/staging-first-sync-proof.yml):
            provisions the dedicated Clerk test account, opens a fresh vault,
            generates the corpus and runs ONE real plugin engine over it
            (first_sync.ts: e2e/headless Replica with the index room wired).
  watch     Dev box (needs SSH to FastRaid): dispatches the CI job, grants the
            account's limits, samples the staging container (BEAM memory,
            container state, counts, index tail), KILLS the container once
            40-60% of notes are on the server, waits for completion and writes
            summary.md for a PR comment.

Staging is ONE Docker container on FastRaid (engram-saas), not ECS, so the
"restart" is `docker kill -s KILL` + `docker start`: the same SIGKILL an OOM
delivers, so `unbind/3` never runs and the tail is NOT folded on the way out,
which is the case #2308 has to survive. `--restart-mode graceful` uses
`docker restart` instead (the ECS force-new-deployment shape).

    # one command, from the dev box, after #2308 is on staging:
    python3 e2e/load/first_sync_proof.py watch --dispatch --out fsproof-out
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import random
import shlex
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
E2E = HERE.parent
sys.path.insert(0, str(E2E))

from load.guards import check_target  # noqa: E402
from load.sim import PNG_HEAD, note_body, note_path  # noqa: E402

# ---------------------------------------------------------------------------
# Targets. Hard-coded staging; every name goes through refuse_prod first.
# ---------------------------------------------------------------------------
STAGING_HOST = "root@10.0.20.214"  # FastRaid
STAGING_APP = "engram-saas"
STAGING_PG = "engram-saas-postgres"
STAGING_HEALTH = "https://staging.engram.page/api/health"
EMAIL = "fsproof-u00+clerk_test@example.com"  # dedicated Clerk test account
PREFIX = "fsproof"  # -> Account(0, api, PREFIX).email == EMAIL
WORKFLOW = "staging-first-sync-proof.yml"
FIX_PR = 2308
PROD_WEB_TASK_MIB = 2048  # engram-infra main/envs/prod/ecs.tf, web memory_mib

# The account's limit overrides (-1 = unlimited, as e2e/load/grant.sql).
OVERRIDES = {
    "notes_cap": -1,
    "attachment_bytes_cap": -1,
    "vaults_cap": -1,
    "embed_token_bucket": -1,
    "concurrent_devices": -1,
    "obsidian_connections_cap": -1,
    "api_rps_cap": 1000,
}


class Refused(SystemExit):
    pass


def refuse_prod(*names: str) -> None:
    """Hard stop: this harness kills containers. Nothing named prod, ever."""
    for n in names:
        if "prod" in n.lower():
            raise Refused(f"refusing {n!r}: names containing 'prod' are never a target")


# ---------------------------------------------------------------------------
# generate
# ---------------------------------------------------------------------------
# Size bands for attachments (bytes): mostly screenshots, some photos, a few
# large scans. Mean ~0.5 MB, so 2,000 attachments is ~1 GB.
ATT_BANDS = [
    (0.70, 50_000, 300_000),
    (0.25, 300_000, 1_500_000),
    (0.05, 1_500_000, 4_000_000),
]


def attachment(seed: int, k: int) -> tuple[str, bytes]:
    rng = random.Random(f"fsproof-att:{seed}:{k}")
    r, acc = rng.random(), 0.0
    for p, lo, hi in ATT_BANDS:
        acc += p
        if r < acc:
            break
    size = rng.randint(lo, hi)
    ext = rng.choice(["png", "png", "jpg", "webp"])
    folder = f"Attachments/{rng.choice(['Screens', 'Photos', 'Scans', 'Diagrams'])}"
    return f"{folder}/img-{k:05d}.{ext}", PNG_HEAD + rng.randbytes(size - len(PNG_HEAD))


def generate(root: Path, notes: int, attachments: int, seed: int) -> dict:
    """Write the corpus under `root` and return its manifest. Same seed, same bytes."""
    if root.exists() and any(root.iterdir()):
        raise SystemExit(f"{root} is not empty; the corpus must be the whole vault")
    digest = hashlib.sha256()
    att_paths, att_bytes = [], 0
    for k in range(attachments):
        p, data = attachment(seed, k)
        (root / p).parent.mkdir(parents=True, exist_ok=True)
        (root / p).write_bytes(data)
        att_paths.append(p)
        att_bytes += len(data)
        digest.update(p.encode() + hashlib.sha256(data).digest())
    rng = random.Random(f"fsproof-embed:{seed}")
    folders = set()
    for i in range(notes):
        # sim.py's corpus, namespaced by the seed in place of an account index.
        p = note_path(seed, i)
        body = note_body(seed, i, notes)
        if att_paths and rng.random() < 0.15:  # some notes embed an attachment
            body += f"\n![[{Path(rng.choice(att_paths)).name}]]\n"
        (root / p).parent.mkdir(parents=True, exist_ok=True)
        (root / p).write_text(body)
        folders.add(str(Path(p).parent))
        digest.update(p.encode() + hashlib.sha256(body.encode()).digest())
    return {
        "seed": seed,
        "notes": notes,
        "attachments": attachments,
        "attachment_bytes": att_bytes,
        "folders": len(folders - {"."}),
        "sha256": digest.hexdigest(),
    }


def cmd_generate(a) -> int:
    root = Path(a.out)
    root.mkdir(parents=True, exist_ok=True)
    t0 = time.time()
    m = generate(root, a.notes, a.attachments, a.seed)
    m["seconds"] = round(time.time() - t0, 1)
    print(json.dumps(m))
    return 0


# ---------------------------------------------------------------------------
# load (CI)
# ---------------------------------------------------------------------------
def cmd_load(a) -> int:
    import requests

    from helpers.clerk import ClerkClient
    from helpers.clerk_auth import ClerkAuth
    from load.guards import check_clerk_key, redact
    from load.sim import (
        Account,
        install_signal_handlers,
        provision,
        register_vault,
        spawn_child,
    )

    check_target(a.api, allow_any_host=False)
    key = os.environ.get("STAGING_CLERK_SECRET_KEY", "")
    check_clerk_key(key)
    install_signal_handlers()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    root = Path(a.work)
    root.mkdir(parents=True, exist_ok=True)
    device = f"fsproof-{a.run_id}"

    # 1. Corpus first: it is the slow part, and the vault should start empty and
    #    see the sync begin straight away.
    t0 = time.time()
    manifest = generate(root / device, a.notes, a.attachments, a.seed)
    log(out, "generated", seconds=round(time.time() - t0, 1), **manifest)

    # 2. The dedicated account; wait for the watcher's limit grant to land.
    clerk = ClerkClient(key)
    acct = Account(0, a.api.removesuffix("/api") + "/api", PREFIX)
    assert acct.email == EMAIL
    provision(acct, clerk, a.run_id)
    deadline = time.time() + 900
    while True:
        u = (
            acct.s(vault=False)
            .get(f"{acct.api}/billing/usage", timeout=30)
            .json()["usage"]
        )
        if u["notes"]["limit"] is None and u["attachment_bytes"]["limit"] is None:
            break
        if time.time() > deadline:
            log(out, "grant_timeout", usage=u)
            return 3
        time.sleep(10)

    # 3. A FRESH vault per run (a first sync needs an empty server vault). Older
    #    proof vaults are deleted and purged so they do not pile up on staging.
    j = requests.Session()
    j.auth = ClerkAuth(clerk, acct.clerk_id)
    for v in (
        acct.s(vault=False)
        .get(f"{acct.api}/vaults", timeout=30)
        .json()
        .get("vaults", [])
    ):
        acct.s(vault=False).delete(f"{acct.api}/vaults/{v['id']}", timeout=60)
        j.post(f"{acct.api}/vaults/{v['id']}/purge", timeout=60)
    acct.client_id = f"{PREFIX}~{a.run_id}"
    register_vault(acct)
    v = (
        acct.s(vault=False)
        .get(f"{acct.api}/vaults/{acct.vault_id}", timeout=30)
        .json()["vault"]
    )
    manifest["baseline_notes"] = v["note_count"]  # a seeded welcome note, if any
    manifest["vault_id"] = acct.vault_id
    (root / f"{device}.manifest.json").write_text(json.dumps(manifest))
    log(out, "vault", vault_id=acct.vault_id, baseline_notes=v["note_count"])

    # 4. The real plugin engine. Its config (live API key) goes on stdin only.
    cfg = {
        "token": acct.key,
        "userId": acct.user_id,
        "vaultId": acct.vault_id,
        "root": str(root.resolve()),
        "id": device,
        "out": str((out / "first_sync.jsonl").resolve()),
        "deadline": time.time() + a.deadline,
        "passGapMs": 60_000,
        "apiUrl": acct.api,
    }
    env = {k: v for k, v in os.environ.items() if k != "STAGING_CLERK_SECRET_KEY"}
    env.update(ENGRAM_API_URL=acct.api)
    child = spawn_child(
        [
            "bun",
            "--preload",
            str(E2E / "headless/preload.ts"),
            str(HERE / "first_sync.ts"),
            "-",
        ],
        cfg,
        env=env,
        log=out / "first_sync.log",
    )
    rc = child.wait()
    # The artifact is public: strip any socket token or API key the engine logged.
    clog = out / "first_sync.log"
    clog.write_text(redact(clog.read_text(errors="replace")))
    final = (
        acct.s(vault=False)
        .get(f"{acct.api}/vaults/{acct.vault_id}", timeout=30)
        .json()["vault"]
    )
    result = {
        "rc": rc,
        "vault_id": acct.vault_id,
        "seed": manifest["seed"],
        "sha256": manifest["sha256"],
        "attachment_bytes": manifest["attachment_bytes"],
        "want_notes": manifest["notes"] + manifest["baseline_notes"],
        "want_attachments": manifest["attachments"],
        "server_notes": final["note_count"],
        "server_attachments": final["attachment_count"],
    }
    (out / "result.json").write_text(json.dumps(result, indent=2))
    log(out, "done", **result)
    # Revoke this run's key: the next run mints its own.
    if acct.key_id:
        j.delete(f"{acct.api}/api-keys/{acct.key_id}", timeout=30)
    return 0 if rc == 0 else 1


def log(out: Path, event: str, **kw) -> None:
    line = json.dumps({"t": time.time(), "event": event, **kw})
    print(line, flush=True)
    with open(out / "load.jsonl", "a") as f:
        f.write(line + "\n")


# ---------------------------------------------------------------------------
# watch (dev box)
# ---------------------------------------------------------------------------
def ssh(
    cmd: str, timeout: int = 60, stdin: str | None = None
) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", STAGING_HOST, cmd],
        input=stdin,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def psql(sql: str, write: bool = False) -> list[list[str]]:
    pre = "" if write else "SET default_transaction_read_only = on;\n"
    r = ssh(
        f"docker exec -i {STAGING_PG} psql -U engram -d engram -X -At -F'|' -v ON_ERROR_STOP=1 -f -",
        stdin=pre + sql,
    )
    if r.returncode != 0:
        raise RuntimeError(f"psql failed: {r.stderr.strip()[:300]}")
    return [ln.split("|") for ln in r.stdout.splitlines() if ln and ln != "SET"]


def gh(*args: str) -> str:
    return subprocess.run(
        ["gh", *args], capture_output=True, text=True, check=True
    ).stdout.strip()


def check_fix_deployed() -> str:
    """Refuse to run unless staging serves a build that contains #2308's merge."""
    import requests

    pr = json.loads(
        gh(
            "pr",
            "view",
            str(FIX_PR),
            "-R",
            "engram-app/Engram",
            "--json",
            "state,mergeCommit",
        )
    )
    if pr["state"] != "MERGED":
        raise Refused(
            f"PR #{FIX_PR} is {pr['state']}, not merged: nothing to prove yet"
        )
    build = requests.get(STAGING_HEALTH, timeout=10).json()
    status = gh(
        "api",
        f"repos/engram-app/Engram/compare/{pr['mergeCommit']['oid']}...{build['build_sha']}",
        "--jq",
        ".status",
    )
    if status not in ("ahead", "identical"):
        raise Refused(
            f"staging build {build['build_sha'][:9]} does not contain #{FIX_PR} ({status}); wait for the auto-deploy"
        )
    return f"{build['version']} ({build['build_sha'][:9]})"


def grant_overrides() -> bool:
    """Idempotent limit grant for the proof account; False until the user row exists."""
    values = ", ".join(
        f"('{k}', '{{\"v\": {v}}}'::jsonb)" for k, v in OVERRIDES.items()
    )
    rows = psql(
        "INSERT INTO user_limit_overrides (user_id, key, value, reason, set_by) "
        f"SELECT u.id, k.key, k.value, 'first-sync-proof', 'first-sync-proof' FROM users u "
        f"CROSS JOIN (VALUES {values}) AS k(key, value) WHERE u.email = '{EMAIL}' "
        "ON CONFLICT (user_id, key) DO UPDATE SET value = EXCLUDED.value, set_at = NOW() RETURNING 1;",
        write=True,
    )
    return len(rows) > 0


def find_vault(run_id: str) -> str | None:
    rows = psql(
        f"select id from vaults where client_id = '{PREFIX}~{run_id}' and deleted_at is null;"
    )
    return rows[0][0] if rows else None


# One SSH round trip per sample: container state, docker stats, BEAM memory.
# `bin/engram rpc` boots a short-lived hidden node in the container (~1 s CPU
# on FastRaid per call), so it runs every sample, not every second.
SAMPLE_SH = (
    f"docker inspect {STAGING_APP} --format "
    "'{{.State.Status}}|{{.State.StartedAt}}|{{.State.OOMKilled}}|{{.State.ExitCode}}|{{.RestartCount}}';"
    f"docker stats --no-stream --format '{{{{.MemUsage}}}}' {STAGING_APP};"
    f"timeout 20 docker exec {STAGING_APP} bin/engram rpc "
    + shlex.quote(
        'm = :erlang.memory(); IO.puts("beam|#{m[:total]}|#{m[:binary]}|#{m[:processes]}")'
    )
    + " 2>/dev/null || echo 'beam|||'"
)


def sample(vault_id: str | None) -> dict:
    s: dict = {"t": time.time()}
    r = ssh(SAMPLE_SH)
    lines = r.stdout.splitlines()
    if len(lines) >= 3:
        st, started, oom, code, restarts = lines[0].split("|")
        s.update(
            status=st,
            started_at=started,
            oom_killed=oom == "true",
            exit_code=int(code),
            restarts=int(restarts),
        )
        s["container_mem"] = lines[1].split("/")[0].strip()
        _, total, binary, procs = lines[-1].split("|")
        if total:
            s.update(
                beam_total=int(total),
                beam_binary=int(binary),
                beam_processes=int(procs),
            )
    if vault_id:
        try:
            (n,), (att,), (rows, nbytes), (snap,) = psql(
                f"select count(*) from notes where vault_id = '{vault_id}' and deleted_at is null and kind = 'note';"
                f"select count(*) from attachments where vault_id = '{vault_id}' and deleted_at is null;"
                f"select count(*), coalesce(sum(octet_length(update_ciphertext)), 0) from vault_index_update_log where vault_id = '{vault_id}';"
                f"select coalesce(max(octet_length(state_ciphertext)), 0) from vault_index_states where vault_id = '{vault_id}';"
            )
            s.update(
                notes=int(n),
                attachments=int(att),
                tail_rows=int(rows),
                tail_bytes=int(nbytes),
                snapshot_bytes=int(snap),
            )
        except (RuntimeError, ValueError) as e:  # DB briefly away during the kill
            s["db_err"] = str(e)[:120]
    return s


TRANSIENT = (RuntimeError, ValueError, subprocess.SubprocessError)


def restart(mode: str) -> dict:
    refuse_prod(STAGING_HOST, STAGING_APP)
    cmd = (
        f"docker kill --signal KILL {STAGING_APP} && docker start {STAGING_APP}"
        if mode == "kill"
        else f"docker restart --time 30 {STAGING_APP}"
    )
    t0 = time.time()
    r = ssh(cmd, timeout=120)
    return {"t": t0, "mode": mode, "rc": r.returncode, "err": r.stderr.strip()[:200]}


def finished(gh_run, s: dict, a) -> bool:
    """The CI load exited (it exits once the server holds the corpus, or gives
    up), or, watching a run started elsewhere, the server counts are full."""
    if not gh_run:
        return s.get("notes", 0) >= a.notes and s.get("attachments", 0) >= a.attachments
    try:
        st = gh(
            "run",
            "view",
            str(gh_run),
            "-R",
            "engram-app/Engram",
            "--json",
            "status",
            "--jq",
            ".status",
        )
    except TRANSIENT:
        return False
    return st == "completed"


def cmd_watch(a) -> int:
    refuse_prod(STAGING_HOST, STAGING_APP, STAGING_PG, a.api)
    check_target(a.api, allow_any_host=False)
    if not 0.4 <= a.restart_at <= 0.6:
        raise SystemExit("--restart-at must be within 0.4-0.6")
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    build = check_fix_deployed() if not a.skip_fix_check else "unchecked"
    run_id = (
        a.run_id
        or datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S") + uuid.uuid4().hex[:4]
    )
    since = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    gh_run = None
    if a.dispatch:
        gh(
            "workflow",
            "run",
            WORKFLOW,
            "-R",
            "engram-app/Engram",
            "--ref",
            a.ref,
            "-f",
            f"run_id={run_id}",
            "-f",
            f"notes={a.notes}",
            "-f",
            f"attachments={a.attachments}",
            "-f",
            f"seed={a.seed}",
            "-f",
            f"api={a.api}",
        )
    print(f"[watch] run_id={run_id} build={build}", flush=True)

    samples = out / "samples.jsonl"
    vault_id, granted, restarted, done_at = None, False, None, None
    end = time.time() + a.deadline
    while time.time() < end:
        # Control-plane lookups retry on the next tick: SSH, psql and gh all
        # blip while the container restarts, and losing the watcher mid-proof
        # loses the evidence.
        try:
            if not granted:
                granted = grant_overrides()
            if vault_id is None:
                vault_id = find_vault(run_id)
            if a.dispatch and gh_run is None:
                runs = json.loads(
                    gh(
                        "run",
                        "list",
                        "-R",
                        "engram-app/Engram",
                        "--workflow",
                        WORKFLOW,
                        "-L",
                        "20",
                        "--json",
                        "databaseId,displayTitle",
                    )
                )
                gh_run = next(
                    (r["databaseId"] for r in runs if run_id in r["displayTitle"]),
                    None,
                )
            s = sample(vault_id)
        except TRANSIENT as e:
            print(f"[watch] transient: {str(e)[:200]}", flush=True)
            time.sleep(a.interval)
            continue
        with open(samples, "a") as f:
            f.write(json.dumps(s) + "\n")
        n = s.get("notes")
        progress = n / a.notes if n is not None else 0.0
        print(
            f"[watch] notes={n} att={s.get('attachments')} tail={s.get('tail_rows')} "
            f"bin={mib(s.get('beam_binary'))} total={mib(s.get('beam_total'))} {s.get('status')}",
            flush=True,
        )
        if restarted is None and progress >= a.restart_at:
            restarted = restart(a.restart_mode) | {
                "progress": round(progress, 3),
                "notes": n,
            }
            (out / "restart.json").write_text(json.dumps(restarted))
            print(f"[watch] RESTART at {progress:.1%}: {restarted}", flush=True)
        if done_at is None and finished(gh_run, s, a):
            done_at = time.time()
        if (
            done_at and time.time() - done_at > a.cooldown
        ):  # keep sampling: a late OOM counts
            break
        time.sleep(a.interval)

    # Container events and log signatures across the whole window.
    until = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    ev = ssh(
        f"docker events --since {since} --until {until} --filter container={STAGING_APP} --format '{{{{json .}}}}'",
        timeout=60,
    )
    (out / "events.jsonl").write_text(ev.stdout)
    logs = {}
    for name, pat in LOG_SIGNATURES.items():
        r = ssh(
            f"docker logs --since {since} {STAGING_APP} 2>&1 | grep -c -E {shlex.quote(pat)}",
            timeout=120,
        )
        logs[name] = int(r.stdout.strip() or 0)

    load_result = None
    if gh_run:
        subprocess.run(
            [
                "gh",
                "run",
                "download",
                str(gh_run),
                "-R",
                "engram-app/Engram",
                "-D",
                str(out / "load"),
            ],
            capture_output=True,
        )
        rp = (
            next((out / "load").rglob("result.json"), None)
            if (out / "load").exists()
            else None
        )
        load_result = json.loads(rp.read_text()) if rp else None

    summary = summarize(
        a,
        run_id,
        build,
        gh_run,
        [json.loads(x) for x in samples.read_text().splitlines()],
        restarted,
        [json.loads(x) for x in ev.stdout.splitlines() if x.strip()],
        logs,
        load_result,
    )
    (out / "summary.md").write_text(summary)
    print(summary)
    return 0 if "**PASS**" in summary.splitlines()[0] else 1


LOG_SIGNATURES = {
    "replay_tail": r"replay_tail",
    "db_checkout_over_15s": r"checked out the connection for longer than",
    "eheap_alloc_or_oom": r"eheap_alloc|Cannot allocate|out of memory",
}


def mib(b) -> str:
    return "-" if b is None else f"{b / 2**20:.0f}MiB"


def summarize(a, run_id, build, gh_run, samples, restarted, events, logs, load) -> str:
    def peak(key, after=0.0):
        vals = [s[key] for s in samples if key in s and s["t"] >= after]
        return max(vals) if vals else None

    after = restarted["t"] if restarted else 0.0
    # Every container death that is not our own kill is an unexpected exit;
    # an `oom` event is an OOM kill however it happened.
    ours = restarted["t"] if restarted else None
    dies = [e for e in events if e.get("status") == "die" or e.get("Action") == "die"]
    unexpected = [e for e in dies if ours is None or abs(e.get("time", 0) - ours) > 15]
    ooms = [e for e in events if (e.get("status") or e.get("Action")) == "oom"] + [
        s for s in samples if s.get("oom_killed")
    ]
    last = next((s for s in reversed(samples) if "notes" in s), {})
    want_notes = load["want_notes"] if load else a.notes
    want_att = load["want_attachments"] if load else a.attachments
    cap = a.max_beam_mib * 2**20
    checks = [
        (
            "restart happened at 40-60% of notes",
            bool(restarted)
            and restarted["rc"] == 0
            and 0.4 <= restarted["progress"] <= 0.6,
        ),
        (f"server notes == {want_notes}", last.get("notes") == want_notes),
        (f"server attachments == {want_att}", last.get("attachments") == want_att),
        ("zero OOM kills (docker oom events, State.OOMKilled)", not ooms),
        ("no container exit other than our kill", not unexpected),
        (
            f"peak BEAM total < {a.max_beam_mib} MiB (prod web task is {PROD_WEB_TASK_MIB} MiB)",
            (peak("beam_total") or 0) < cap,
        ),
        (
            f"peak index tail rows < {a.max_tail_rows}",
            (peak("tail_rows") or 0) < a.max_tail_rows,
        ),
        ("no DB checkout > 15 s in the logs", logs.get("db_checkout_over_15s", 0) == 0),
    ]
    ok = all(c for _, c in checks)
    lines = [
        f"## Staging first-sync proof: {'**PASS**' if ok else '**FAIL**'}",
        "",
        f"Run `{run_id}` against staging {build}. Corpus: {a.notes} notes + {a.attachments} attachments, seed {a.seed}"
        + (
            f", {load['attachment_bytes'] / 2**20:.0f} MiB of attachments, corpus sha256 `{load['sha256'][:12]}`"
            if load
            else ""
        )
        + ".",
        "Load: one real plugin engine (e2e/headless Replica, index room wired) running `fullSync`"
        + (f", CI run {gh_run}" if gh_run else "")
        + ".",
        f"Restart: `{restarted['mode'] if restarted else '-'}` of `{STAGING_APP}` at "
        + (
            f"{restarted['progress']:.0%} ({restarted['notes']} notes)"
            if restarted
            else "never"
        )
        + ".",
        "",
        "| Check | Result |",
        "|---|---|",
        *[f"| {name} | {'ok' if c else 'FAILED'} |" for name, c in checks],
        "",
        "| Metric | Whole run | After restart |",
        "|---|---|---|",
        f"| Peak BEAM binary | {mib(peak('beam_binary'))} | {mib(peak('beam_binary', after))} |",
        f"| Peak BEAM total | {mib(peak('beam_total'))} | {mib(peak('beam_total', after))} |",
        f"| Peak index tail rows | {peak('tail_rows')} | {peak('tail_rows', after)} |",
        f"| Peak index tail bytes | {peak('tail_bytes')} | {peak('tail_bytes', after)} |",
        f"| Final notes / attachments | {last.get('notes')} / {last.get('attachments')} | |",
        f"| Container deaths (ours / unexpected) | {len(dies) - len(unexpected)} / {len(unexpected)} | |",
        "",
        "Log signatures over the window: "
        + ", ".join(f"`{k}` {v}" for k, v in logs.items())
        + ".",
        "",
        "<details><summary>Samples (time, notes, tail rows, BEAM binary, BEAM total)</summary>",
        "",
        "```",
        *[
            f"{datetime.fromtimestamp(s['t'], timezone.utc):%H:%M:%S} {s.get('notes', '-'):>6} {s.get('tail_rows', '-'):>6} "
            f"{mib(s.get('beam_binary')):>8} {mib(s.get('beam_total')):>8} {s.get('status', '?')}"
            for s in samples[:: max(1, len(samples) // 120)]
        ],
        "```",
        "</details>",
        "",
        "Not covered: staging is one Docker node with no memory limit, so a breach shows as the BEAM cap check "
        "above rather than a kernel OOM kill, and there is no second node for the `:global` room to move to.",
    ]
    return "\n".join(lines) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = ap.add_subparsers(dest="cmd", required=True)

    def corpus(p):
        p.add_argument("--notes", type=int, default=30_000)
        p.add_argument("--attachments", type=int, default=2_000)
        p.add_argument("--seed", type=int, default=2306)

    g = sub.add_parser("generate")
    corpus(g)
    g.add_argument("--out", required=True)

    ld = sub.add_parser("load")
    corpus(ld)
    ld.add_argument("--api", default="http://10.0.20.214:8000/api")
    ld.add_argument("--run-id", required=True)
    ld.add_argument("--work", default="fsproof-work")
    ld.add_argument("--out", default="fsproof-out")
    ld.add_argument(
        "--deadline", type=int, default=3 * 3600, help="seconds for the sync to finish"
    )

    w = sub.add_parser("watch")
    corpus(w)
    w.add_argument(
        "--api", default="http://10.0.20.214:8000/api", help="passed to the CI load job"
    )
    w.add_argument(
        "--dispatch",
        action="store_true",
        help="start the CI load job (else watch --run-id)",
    )
    w.add_argument("--ref", default="main", help="git ref the CI job runs")
    w.add_argument("--run-id")
    w.add_argument("--out", default="fsproof-out")
    w.add_argument("--restart-at", type=float, default=0.5)
    w.add_argument("--restart-mode", choices=["kill", "graceful"], default="kill")
    w.add_argument("--interval", type=int, default=15)
    w.add_argument(
        "--cooldown",
        type=int,
        default=180,
        help="seconds to keep sampling after completion",
    )
    w.add_argument("--deadline", type=int, default=4 * 3600)
    w.add_argument(
        "--max-beam-mib",
        type=int,
        default=1536,
        help="75%% of the prod web task's 2 GiB",
    )
    w.add_argument(
        "--max-tail-rows",
        type=int,
        default=5000,
        help="10x the #2308 fold threshold (500)",
    )
    w.add_argument(
        "--skip-fix-check",
        action="store_true",
        help="rehearsal only: skip the #2308-on-staging check",
    )

    a = ap.parse_args()
    return {"generate": cmd_generate, "load": cmd_load, "watch": cmd_watch}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
