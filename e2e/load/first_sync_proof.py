#!/usr/bin/env python3
"""Staging proof: a 30k-note + attachments first sync survives a server kill mid-sync.

Regression proof for the 2026-10-29 prod crash loop (Engram#2306, fix PR #2308):
a bulk first sync grew the per-vault CRDT index room's update tail, every
restart re-bound the room and replayed that tail, and the replay OOM-killed the
node again (docs/context/web-oom-index-room-tail-replay-2026-10-29.md).

Subcommands:

  generate  Deterministic synthetic vault (notes + attachments) from a seed.
  load      Runs on the load host (the CI runner VM, over SSH): generates the
            corpus, opens a fresh vault and runs ONE real plugin engine over it
            (first_sync.ts: e2e/headless Replica with the index room wired).
            Authenticates with an Engram API key read from STDIN, so the key
            never touches argv, env, disk or a log.
  watch     Dev box (needs SSH to FastRaid and to the load host): creates a
            throwaway staging user through the release rpc (no Clerk secret),
            grants its limits, mints its key, starts `load` on the load host
            under a memory cap, samples the staging container (BEAM memory,
            container state, counts, index tail), KILLS the container once
            40-60% of notes are on the server, waits for completion, writes
            summary.md for a PR comment, and always cleans up (key, user and
            its data, the load host's temp dir).

Staging is ONE Docker container on FastRaid (engram-saas), not ECS, so the
"restart" is `docker kill -s KILL` + `docker start`: the same SIGKILL an OOM
delivers, so `unbind/3` never runs and the tail is NOT folded on the way out,
which is the case #2308 has to survive. `--restart-mode graceful` uses
`docker restart` instead (the ECS force-new-deployment shape).

    # one command, from the dev box, after #2308 is on staging:
    python3 e2e/load/first_sync_proof.py watch --out fsproof-out
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
REPO = E2E.parent
sys.path.insert(0, str(E2E))

from load.guards import check_target, redact  # noqa: E402
from load.sim import PNG_HEAD, note_body, note_path  # noqa: E402

# ---------------------------------------------------------------------------
# Targets. Hard-coded staging; every name goes through refuse_prod first.
# ---------------------------------------------------------------------------
STAGING_HOST = "root@10.0.20.214"  # FastRaid
STAGING_APP = "engram-saas"
STAGING_PG = "engram-saas-postgres"
STAGING_HEALTH = "https://staging.engram.page/api/health"
LOAD_HOST = "gh-runner"  # the isolated CI runner VM (docs/context/runner-vm-setup.md)
PREFIX = "fsproof"
PLUGIN_REPO = "https://github.com/engram-app/Engram-obsidian.git"
NPM_MIRROR = "http://10.0.20.214:4873"
QDRANT_URL = "http://10.0.20.201:6333"  # staging's
# Queues whose workers write to Qdrant (EmbedNote, RefreshKeywordVectors,
# RepathNoteIndex on :embed; ExtractNoteLinks, DeleteNoteIndex on :indexing).
# Staging shares that Qdrant with CI (Engram#2318), so they stay paused for the
# whole run. Oban keeps pauses in memory: every container start resumes them,
# so the watcher re-pauses after each start it sees. Any point the run user
# owns means a write got through, and aborts the run.
QDRANT_QUEUES = ("embed", "indexing")
FIX_PR = 2308
PROD_WEB_TASK_MIB = 2048  # engram-infra main/envs/prod/ecs.tf, web memory_mib

# The throwaway account's limit overrides (-1 = unlimited, as e2e/load/grant.sql).
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


def email_for(run_id: str) -> str:
    return f"{PREFIX}-{run_id}+clerk_test@example.com"


# ---------------------------------------------------------------------------
# generate
# ---------------------------------------------------------------------------
# Attachment sizes (bytes). Tiny on purpose: the index room sees one path
# claim per file whatever its size, and that tail is what this proves, so 2,000
# attachments of 1-20 KB (~20 MB) exercise it as well as ~1 GB would, faster.
ATT_BANDS = [(1.0, 1_000, 20_000)]


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
# load (the load host)
# ---------------------------------------------------------------------------
def cmd_load(a) -> int:
    from load.sim import Account, install_signal_handlers, register_vault, spawn_child

    check_target(a.api, allow_any_host=False)
    key = sys.stdin.readline().strip()  # stdin only: never argv, env or disk
    if not key.startswith("engram_"):
        raise SystemExit("load: expected an Engram API key on stdin")
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    clog = out / "first_sync.log"

    def redact_log() -> None:  # the child's log can echo the key (socket URL)
        if clog.exists():
            clog.write_text(redact(clog.read_text(errors="replace")))

    install_signal_handlers(on_exit=redact_log)
    root = Path(a.work)
    root.mkdir(parents=True, exist_ok=True)
    device = f"{PREFIX}-{a.run_id}"

    # 1. Corpus first: it is the slow part, and the vault should start empty and
    #    see the sync begin straight away.
    t0 = time.time()
    manifest = generate(root / device, a.notes, a.attachments, a.seed)
    log(out, "generated", seconds=round(time.time() - t0, 1), **manifest)

    # 2. A fresh vault on the throwaway account (accept_terms may have opened a
    #    connector vault; the first sync gets its own).
    acct = Account(0, a.api, PREFIX)
    acct.key = key
    acct.user_id = (
        acct.s(vault=False).get(f"{acct.api}/me", timeout=30).json()["user"]["id"]
    )
    acct.client_id = f"{PREFIX}~{a.run_id}"
    register_vault(acct)
    v = (
        acct.s(vault=False)
        .get(f"{acct.api}/vaults/{acct.vault_id}", timeout=30)
        .json()["vault"]
    )
    manifest["baseline_notes"] = v["note_count"]  # a seeded welcome note, if any
    (root / f"{device}.manifest.json").write_text(json.dumps(manifest))
    log(out, "vault", vault_id=acct.vault_id, baseline_notes=v["note_count"])

    # 3. The real plugin engine. Its config (the key) goes on its stdin only.
    cfg = {
        "token": key,
        "userId": acct.user_id,
        "vaultId": acct.vault_id,
        "root": str(root.resolve()),
        "id": device,
        "out": str((out / "first_sync.jsonl").resolve()),
        "deadline": time.time() + a.deadline,
        "passGapMs": 60_000,
        "apiUrl": acct.api,
    }
    child = spawn_child(
        [
            "bun",
            "--preload",
            str(E2E / "headless/preload.ts"),
            str(HERE / "first_sync.ts"),
            "-",
        ],
        cfg,
        # run.ts reads the API base from the env (default: a local CI stack).
        env={**os.environ, "ENGRAM_API_URL": acct.api},
        log=clog,
    )
    try:
        rc = child.wait()
    finally:
        redact_log()
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
    cmd: str, timeout: int = 60, stdin: str | None = None, host: str = STAGING_HOST
) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host, cmd],
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


def rpc(expr: str, timeout: int = 120) -> str:
    """Evaluate Elixir on the staging release (e2e/helpers/backend_rpc.py's seam).

    The output can hold a live key: callers parse it and never print it."""
    r = ssh(
        f"docker exec -i {STAGING_APP} bin/engram rpc {shlex.quote(expr)}",
        timeout=timeout,
    )
    if r.returncode != 0:
        # An Elixir raise prints to stdout; redact in case it echoes a key.
        detail = redact(f"{r.stderr.strip()[:300]} {r.stdout.strip()[-300:]}")
        raise RuntimeError(f"rpc failed ({r.returncode}): {detail}")
    return r.stdout


def rpc_field(out: str, tag: str) -> list[str]:
    line = next((ln for ln in out.splitlines() if ln.startswith(f"{tag}|")), None)
    if line is None:
        raise RuntimeError(f"rpc gave no {tag} line")
    return line.split("|")[1:]


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


# ---------------------------------------------------------------------------
# The throwaway account: created, keyed and deleted through the release rpc,
# so no Clerk secret is involved. external_id is synthetic and never signs in.
# ---------------------------------------------------------------------------
def create_user(run_id: str) -> str:
    """Create + onboard the run's user (terms, Free start, profile); returns its id."""
    out = rpc(
        f"""
        {{:ok, u}} = Engram.Accounts.find_or_create_by_external_id("{PREFIX}-{run_id}", %{{email: "{email_for(run_id)}"}})
        s = Engram.Onboarding.status(u)
        m = Engram.Legal.Manifest.read()
        tv = s.current_tos_version
        pv = s.current_privacy_version
        {{:ok, _}} = Engram.Onboarding.accept_terms(u, tv, m["terms_of_service"][tv], pv, m["privacy_policy"][pv], %{{}})
        {{:ok, _}} = Engram.Onboarding.set_profile(u, %{{uses_obsidian: true, tools: ["claude"]}})
        IO.puts("uid|#{{u.id}}")
        """
    )
    return rpc_field(out, "uid")[0]


def grant_overrides(run_id: str) -> int:
    """The run user's limit overrides, nobody else's; returns rows written."""
    values = ", ".join(
        f"('{k}', '{{\"v\": {v}}}'::jsonb)" for k, v in OVERRIDES.items()
    )
    rows = psql(
        "INSERT INTO user_limit_overrides (user_id, key, value, reason, set_by) "
        "SELECT u.id, k.key, k.value, 'first-sync-proof', 'first-sync-proof' FROM users u "
        f"CROSS JOIN (VALUES {values}) AS k(key, value) WHERE u.email = '{email_for(run_id)}' "
        "ON CONFLICT (user_id, key) DO UPDATE SET value = EXCLUDED.value, set_at = NOW() RETURNING 1;",
        write=True,
    )
    return sum(1 for r in rows if r == ["1"])  # psql also prints the INSERT tag


def mint_key(user_id: str) -> tuple[str, str]:
    """(raw key, key id). The raw key lives only in this process's memory."""
    raw, key_id = rpc_field(
        rpc(
            f"""
            u = Engram.Accounts.get_user!("{user_id}")
            {{:ok, raw, k}} = Engram.Accounts.create_api_key(u, "{PREFIX}")
            IO.puts("key|#{{raw}}|#{{k.id}}")
            """
        ),
        "key",
    )
    return raw, key_id


def wait_rpc(timeout: int = 300) -> None:
    """Block until the staging release answers rpc (a fresh container boots for ~30s)."""
    end = time.time() + timeout
    while True:
        try:
            rpc('IO.puts("up")', timeout=30)
            return
        except (RuntimeError, subprocess.TimeoutExpired):
            if time.time() > end:
                raise
            time.sleep(5)


DELETE_TRIES = 4
# delete_account can deadlock (40P01) with the FolderTable backfill
# (Engram#2339): it raises, or rolls back as :pg_failed. A retry clears it.
RETRYABLE_DELETE = ("40P01", "deadlock", ":pg_failed")


def delete_user(user_id: str, key_id: str | None) -> str:
    """Revoke the key, then hard-delete the user and everything it owns
    (notes, attachments, Qdrant points, vaults). Idempotent, so retried on a
    deadlock; raises unless the user is gone."""
    for attempt in range(1, DELETE_TRIES + 1):
        try:
            res = rpc_field(
                rpc(
                    f"""
                    case Engram.Accounts.get_user("{user_id}") do
                      nil -> IO.puts("del|gone")
                      u ->
                        {"Engram.Accounts.revoke_api_key(u, " + json.dumps(key_id) + ")" if key_id else ":ok"}
                        IO.puts("del|#{{inspect(Engram.Accounts.Lifecycle.delete_account(u, :user))}}")
                    end
                    """,
                    timeout=900,
                ),
                "del",
            )[0]
        except RuntimeError as e:
            res = str(e)
        if res in (":ok", "gone"):
            return res
        if attempt == DELETE_TRIES or not any(m in res for m in RETRYABLE_DELETE):
            raise RuntimeError(f"delete_user {user_id}: {res[:300]}")
        print(f"[watch] delete_user retry {attempt}: {res[:120]}", flush=True)
        time.sleep(15)
    raise AssertionError("unreachable")


def pause_qdrant_queues(pause: bool) -> None:
    fn = "pause_queue" if pause else "resume_queue"
    qs = ", ".join(f":{q}" for q in QDRANT_QUEUES)
    out = rpc(
        f"for q <- [{qs}], do: Oban.{fn}(queue: q)\n"
        f'IO.puts("paused|#{{Enum.all?([{qs}], &Oban.check_queue(queue: &1).paused)}}")'
    )
    if rpc_field(out, "paused")[0] != str(pause).lower():
        raise RuntimeError(f"could not {fn} {QDRANT_QUEUES}")


def cancel_user_jobs(user_id: str) -> str:
    """Cancel the run user's pending jobs in the Qdrant queues, nobody else's."""
    qs = ", ".join(f'"{q}"' for q in QDRANT_QUEUES)
    out = rpc(
        f"""
        import Ecto.Query
        q = from(j in Oban.Job,
          where: j.queue in [{qs}] and j.state in ["available", "scheduled", "retryable"]
            and fragment("?->>?", j.args, "user_id") == "{user_id}")
        IO.puts("cancelled|#{{inspect(Oban.cancel_all_jobs(q))}}")
        """
    )
    return rpc_field(out, "cancelled")[0]


def qdrant_scope(user_id: str) -> tuple[str, dict]:
    """(count URL, filter) for the run user's points only: the collection is
    shared with CI, so its total moves under us. The backend names the
    collection and builds the filter (`Qdrant.match_filter/2`, the indexed
    tenant key in whichever payload format staging writes), so no key name is
    guessed here (docs/context/qdrant-strict-mode-unindexed-filter.md)."""
    col, *cond = rpc_field(
        rpc(
            f'''
            alias Engram.Vector.Qdrant
            IO.puts("qdrant|" <> Qdrant.collection_name() <> "|" <> Jason.encode!(Qdrant.match_filter(:user, "{user_id}")))
            '''
        ),
        "qdrant",
    )
    return f"{QDRANT_URL}/collections/{col}/points/count", {
        "must": [json.loads("|".join(cond))]
    }


def qdrant_points(scope: tuple[str, dict]) -> int:
    import requests

    url, flt = scope
    r = requests.post(url, json={"filter": flt, "exact": True}, timeout=10)
    r.raise_for_status()
    return r.json()["result"]["count"]


def find_vault(run_id: str) -> str | None:
    rows = psql(
        f"select id from vaults where client_id = '{PREFIX}~{run_id}' and deleted_at is null;"
    )
    return rows[0][0] if rows else None


# ---------------------------------------------------------------------------
# The load host: a temp dir with this checkout's e2e/, the plugin and its deps.
# ---------------------------------------------------------------------------
def stage_load_host(host: str, plugin_ref: str) -> str:
    refuse_prod(host)
    r = ssh("mktemp -d /tmp/fsproof.XXXXXX", host=host)
    work = r.stdout.strip()
    if r.returncode != 0 or not work.startswith("/tmp/fsproof."):
        raise RuntimeError(f"mktemp on {host} failed: {r.stderr.strip()[:200]}")
    # The working tree's e2e/ (this harness may not be on main yet).
    tar = subprocess.run(
        ["tar", "-C", str(REPO), "-c", "--exclude=__pycache__", "e2e"],
        capture_output=True,
        check=True,
    )
    up = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", host, f"tar -C {work} -x"],
        input=tar.stdout,
        capture_output=True,
    )
    if up.returncode != 0:
        raise RuntimeError(f"copy to {host} failed: {up.stderr.decode()[:200]}")
    r = ssh(
        f"cd {work} && git clone -q --depth=1 --branch {shlex.quote(plugin_ref)} {PLUGIN_REPO} plugin"
        f" && cd plugin && bun install --frozen-lockfile --registry {NPM_MIRROR} >/dev/null",
        timeout=600,
        host=host,
    )
    if r.returncode != 0:
        raise RuntimeError(f"plugin setup on {host} failed: {r.stderr.strip()[-300:]}")
    return work


def start_load(host: str, work: str, key: str, a, run_id: str) -> subprocess.Popen:
    """`load` on the load host under a 4 GB / 2-core cap, the key on its stdin."""
    cmd = (
        f"cd {work} && systemd-run --user --scope --quiet -p MemoryMax=4G -p CPUQuota=200%"
        f" env ENGRAM_PLUGIN_SRC={work}/plugin python3 e2e/load/first_sync_proof.py load"
        f" --api {shlex.quote(a.api)} --run-id {run_id} --notes {a.notes}"
        f" --attachments {a.attachments} --seed {a.seed} --work {work}/work --out {work}/out"
    )
    p = subprocess.Popen(
        ["ssh", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=30", host, cmd],
        stdin=subprocess.PIPE,
        stdout=open(Path(a.out) / "load_host.log", "w"),
        stderr=subprocess.STDOUT,
        text=True,
    )
    p.stdin.write(key + "\n")
    p.stdin.close()
    return p


def fetch_and_clean_load_host(host: str, work: str, out: Path) -> None:
    if not work.startswith("/tmp/fsproof."):
        raise RuntimeError(f"refusing to clean {work!r}")
    # The load may still run (an abort): stop it first, so its signal handler
    # redacts its log before the copy, and before removing its files. `[/]`
    # matches "/" in the load's argv but not in this shell's own argv, which
    # holds the pattern text; a plain `{work}/` killed the shell itself.
    pattern = shlex.quote(f"[/]{work[1:]}/")
    ssh(f"pkill -f {pattern}; sleep 5", host=host, timeout=60)
    dest = out / "load"
    dest.mkdir(exist_ok=True)
    tar = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", host, f"tar -C {work} -c out"],
        capture_output=True,
        timeout=300,
    )
    if tar.returncode == 0:
        subprocess.run(["tar", "-C", str(dest), "-x"], input=tar.stdout, timeout=300)
        # Backstop for a load that died without redacting (SIGKILL, a hang).
        for f in dest.rglob("*"):
            if f.is_file():
                f.write_text(redact(f.read_text(errors="replace")))
    ssh(f"rm -rf {work}", host=host, timeout=300)


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


def wait_for_fix(minutes: int) -> str:
    """Poll every 2 min until staging serves a build with #2308 in it."""
    end = time.time() + minutes * 60
    while True:
        try:
            return check_fix_deployed()
        except Refused as e:
            if time.time() > end:
                raise
            print(f"[watch] {e}; polling again in 2 min", flush=True)
            time.sleep(120)


def cmd_watch(a) -> int:
    refuse_prod(STAGING_HOST, STAGING_APP, STAGING_PG, a.api, a.load_host)
    check_target(a.api, allow_any_host=False)
    if not 0.4 <= a.restart_at <= 0.6:
        raise SystemExit("--restart-at must be within 0.4-0.6")
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    build = wait_for_fix(a.wait_fix_minutes) if not a.skip_fix_check else "unchecked"
    run_id = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S") + uuid.uuid4().hex[:4]
    since = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(f"[watch] run_id={run_id} build={build}", flush=True)

    user_id = key_id = work = None
    load_rc = None
    restarted = None
    samples = out / "samples.jsonl"
    paused = False
    try:
        paused = (
            True  # before the call: a pause that lands then raises still gets resumed
        )
        pause_qdrant_queues(True)
        started_at = sample(None).get("started_at")
        user_id = create_user(run_id)
        scope = qdrant_scope(user_id)
        if grant_overrides(run_id) != len(OVERRIDES):
            raise RuntimeError("limit grant did not land")
        key, key_id = mint_key(user_id)
        work = stage_load_host(a.load_host, a.plugin_ref)
        load = start_load(a.load_host, work, key, a, run_id)
        del key
        print(f"[watch] load started on {a.load_host}", flush=True)

        vault_id, done_at = None, None
        end = time.time() + a.deadline
        while time.time() < end:
            try:
                if vault_id is None:
                    vault_id = find_vault(run_id)
                s = sample(vault_id)
            except TRANSIENT as e:  # SSH/psql blip, often our own kill
                print(f"[watch] transient: {str(e)[:200]}", flush=True)
                time.sleep(a.interval)
                continue
            try:
                s["qdrant_points"] = qdrant_points(scope)
            except (
                OSError,
                KeyError,
                ValueError,
            ) as e:  # recorded; a miss is not a rise
                s["qdrant_err"] = str(e)[:120]
            with open(samples, "a") as f:
                f.write(json.dumps(s) + "\n")
            if s.get("qdrant_points", 0) > 0:
                raise RuntimeError(
                    f"the run user has {s['qdrant_points']} Qdrant points; aborting"
                )
            if s.get("started_at") and s["started_at"] != started_at:
                started_at = s["started_at"]
                if restarted is None or time.time() - restarted["t"] > 180:
                    # A deploy (staging follows main) or a crash: either way not
                    # the controlled kill this proof is about.
                    raise RuntimeError(
                        f"container restarted outside the proof at {started_at}; aborting"
                    )
                pause_qdrant_queues(True)  # our own kill resumed them
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
                if restarted["rc"] != 0:
                    raise RuntimeError(f"restart failed: {restarted['err']}")
            if done_at is None and load.poll() is not None:
                load_rc, done_at = load.returncode, time.time()
            if (
                done_at and time.time() - done_at > a.cooldown
            ):  # a late OOM still counts
                break
            time.sleep(a.interval)
        else:
            load.terminate()
            raise RuntimeError("watch deadline passed before the load finished")
    finally:
        # If the run itself raised, that error propagates; cleanup's own
        # errors are printed as they happen and raised after the summary.
        ev, logs, errors = cleanup(a, out, since, work, user_id, key_id, paused)

    rp = out / "load" / "out" / "result.json"
    load_result = json.loads(rp.read_text()) if rp.exists() else None
    summary = summarize(
        a,
        run_id,
        build,
        f"{a.load_host} (exit {load_rc})",
        [json.loads(x) for x in samples.read_text().splitlines()]
        if samples.exists()
        else [],
        restarted,
        [json.loads(x) for x in ev.splitlines() if x.strip()],
        logs,
        load_result,
    )
    (out / "summary.md").write_text(summary)
    print(summary)
    if errors:
        raise RuntimeError(f"cleanup failed: {errors}")
    return 0 if "**PASS**" in summary.splitlines()[0] else 1


def cleanup(a, out: Path, since: str, work, user_id, key_id, paused: bool):
    """Evidence, then the throwaway state. Every step runs whatever the others
    did: one raising step used to skip the rest, leaving the user and its
    grants behind and the embed/indexing queues paused for ALL of staging.
    Returns (docker events text, log signature counts, errors)."""
    errors: list[str] = []

    def step(name, fn):
        try:
            return fn()
        except Exception as e:  # collected, printed, raised by the caller
            errors.append(f"{name}: {redact(str(e))[:300]}")
            print(f"[watch] cleanup step failed: {errors[-1]}", flush=True)
            return None

    until = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    ev = step(
        "docker events",
        lambda: (
            ssh(
                f"docker events --since {since} --until {until} --filter container={STAGING_APP} --format '{{{{json .}}}}'",
                timeout=60,
            ).stdout
        ),
    )
    ev = ev or ""
    (out / "events.jsonl").write_text(ev)
    logs = {}
    for name, pat in LOG_SIGNATURES.items():
        n = step(
            f"docker logs {name}",
            lambda pat=pat: int(
                ssh(
                    f"docker logs --since {since} {STAGING_APP} 2>&1 | grep -c -E {shlex.quote(pat)}",
                    timeout=120,
                ).stdout.strip()
                or 0
            ),
        )
        if n is not None:
            logs[name] = n
    if work:
        step("load host", lambda: fetch_and_clean_load_host(a.load_host, work, out))
    if paused or user_id:
        try:
            # A restart leaves a container that is still booting (rpc
            # :noconnection) with the queues resumed: wait, re-pause, cancel
            # the user's jobs, then delete, so nothing embeds into the shared
            # Qdrant.
            up = step("wait rpc", lambda: wait_rpc() or True)
            if up and paused:
                step("re-pause queues", lambda: pause_qdrant_queues(True))
            if up and user_id:
                step(
                    "cancel jobs",
                    lambda: print(
                        f"[watch] cancelled jobs: {cancel_user_jobs(user_id)}",
                        flush=True,
                    ),
                )
                step(
                    "delete user",
                    lambda: print(
                        f"[watch] cleanup: {delete_user(user_id, key_id)}", flush=True
                    ),
                )
        finally:
            if paused:  # last, always: never leave staging's queues paused
                step("resume queues", lambda: pause_qdrant_queues(False))
    if errors and user_id:
        print(
            f"[watch] OPERATOR ACTION: cleanup incomplete; check user {user_id} is deleted "
            f"and Oban queues {QDRANT_QUEUES} are running on {STAGING_APP}",
            flush=True,
        )
    return ev, logs, errors


LOG_SIGNATURES = {
    "replay_tail": r"replay_tail",
    "db_checkout_over_15s": r"checked out the connection for longer than",
    "eheap_alloc_or_oom": r"eheap_alloc|Cannot allocate|out of memory",
}


def mib(b) -> str:
    return "-" if b is None else f"{b / 2**20:.0f}MiB"


def summarize(a, run_id, build, where, samples, restarted, events, logs, load) -> str:
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
        f"Load: one real plugin engine (e2e/headless Replica, index room wired) running `fullSync` on {where}.",
        f"Restart: `{restarted['mode'] if restarted else '-'}` of `{STAGING_APP}` at "
        + (
            f"{datetime.fromtimestamp(restarted['t'], timezone.utc):%Y-%m-%d %H:%M:%SZ}, "
            f"{restarted['progress']:.0%} of notes ({restarted['notes']})"
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
        f"| OOM kills | {len(ooms)} | |",
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
        "Choices: attachments are 1-20 KB (the index tail sees one claim per file, not its bytes); "
        "the plugin's own default push concurrency; the Qdrant-writing Oban queues (embed, indexing) are paused "
        "for the run and the user's jobs cancelled after, so the pass does not wait on (or cause) embeddings or indexing.",
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
        p.add_argument("--api", default="http://10.0.20.214:8000/api")

    g = sub.add_parser("generate")
    corpus(g)
    g.add_argument("--out", required=True)

    ld = sub.add_parser("load", help="reads the API key from stdin")
    corpus(ld)
    ld.add_argument("--run-id", required=True)
    ld.add_argument("--work", required=True)
    ld.add_argument("--out", required=True)
    ld.add_argument(
        "--deadline", type=int, default=3 * 3600, help="seconds for the sync to finish"
    )

    w = sub.add_parser("watch")
    corpus(w)
    w.add_argument("--out", default="fsproof-out")
    w.add_argument("--load-host", default=LOAD_HOST, help="ssh alias of the load host")
    w.add_argument("--plugin-ref", default="main")
    w.add_argument("--restart-at", type=float, default=0.5)
    w.add_argument("--restart-mode", choices=["kill", "graceful"], default="kill")
    w.add_argument("--interval", type=int, default=15)
    w.add_argument(
        "--cooldown",
        type=int,
        default=180,
        help="seconds to keep sampling after the load exits",
    )
    w.add_argument("--deadline", type=int, default=4 * 3600)
    w.add_argument("--wait-fix-minutes", type=int, default=60)
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
