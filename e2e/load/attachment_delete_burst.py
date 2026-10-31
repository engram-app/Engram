#!/usr/bin/env python3
"""Staging repro: a burst of concurrent single attachment DELETEs on one vault.

Incident (prod, 2026-10-31 06:47Z): one Obsidian client sent ~400-533
concurrent `DELETE /api/attachments/*path` to one vault in ~3 s. Each delete
waited on the vaults.change_seq row lock while holding a web pool connection
(POOL_SIZE 10), the pool drained, and unrelated requests (auth, onboarding)
failed with `DBConnection.ConnectionError ... dropped from queue`. Fix:
Engram#2356 (SeqGate: wait for the vault lock in the BEAM, not on the pool).

Steps: seed N small text attachments in a fresh vault (rate-limited), probe
the PROBES every 100 ms for a baseline, fire N DELETEs at once,
keep probing through the burst and a tail, then compare. Grep the staging
container log for pool errors in the window, and always clean up.

Credentials: by default a throwaway user is created, keyed and hard-deleted
through the staging release rpc (first_sync_proof's helpers; needs SSH to
FastRaid, no Clerk secret, no real user). Or set the env var named by
--key-env to an existing TEST user's API key plus --vault-id.

Attachments only: no note is written, so nothing embeds and nothing reaches
the Qdrant staging shares with CI (attachment writes enqueue no Oban job, and
the vault is created via rpc, which skips the welcome note).

    # before / after #2356 (staging auto-follows main; check /health build_sha)
    python3 e2e/load/attachment_delete_burst.py --out /tmp/delburst-before
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import subprocess
import sys
import threading
import time
import uuid
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote, urlsplit

import httpx

E2E = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(E2E))

from load.first_sync_proof import (  # noqa: E402
    STAGING_APP,
    create_user,
    delete_user,
    grant_overrides,
    mint_key,
    rpc,
    rpc_field,
    ssh,
)
from load.guards import check_target, redact  # noqa: E402

DEFAULT_API = (
    "http://10.0.20.214:8000/api"  # staging container on the LAN, past Cloudflare
)
# Each must need a Repo checkout: `GET /me` does NOT (API key and user are
# cached), so it stayed flat through a burst that queued the pool. /health is
# the no-DB control.
# PreAuthRateLimit: 600 req / 60 s per (endpoint family, IP, key). Seeding
# spends the attachments bucket, so the burst starts a full window after it or
# a third of the deletes 429 on the seed's budget (they did). The incident's
# 400-533 in 3 s fit under it.
PREAUTH_WINDOW_S = 61
PROBES = ("/vaults", "/health/deep", "/health")
POOL_ERRORS = ("DBConnection.ConnectionError", "dropped from queue")


def pct(xs: list[float], p: float) -> float | None:
    if not xs:
        return None
    xs = sorted(xs)
    return round(xs[min(len(xs) - 1, int(p / 100 * len(xs)))], 1)


def create_vault(user_id: str, run_id: str) -> str:
    """Vault via rpc: the REST register seeds a welcome NOTE, which embeds."""
    out = rpc(
        f"""
        u = Engram.Accounts.get_user!("{user_id}")
        {{:ok, u}} = Engram.Crypto.ensure_user_dek(u)
        {{:ok, v, _}} = Engram.Vaults.register_vault(u, "delburst-{run_id}", "delburst~{run_id}", %{{}}, create?: true)
        IO.puts("vault|#{{v.id}}")
        """
    )
    return rpc_field(out, "vault")[0]


def path_of(k: int) -> str:
    return f"DelBurst/f{k:04d}.txt"


async def seed(c: httpx.AsyncClient, n: int, rate: float) -> Counter:
    sem, st = asyncio.Semaphore(8), Counter()

    async def one(k: int):
        async with sem:
            body = {
                "path": path_of(k),
                "mime_type": "text/plain",
                "mtime": time.time(),
                "content_base64": "ZGVsYnVyc3QK",
            }  # "delburst\n"
            for _ in range(5):
                r = await c.post("/attachments", json=body)
                if r.status_code != 429:
                    break
                await asyncio.sleep(2)
            st[r.status_code] += 1
            await asyncio.sleep(8 / rate)  # ~rate req/s across 8 workers

    await asyncio.gather(*(one(k) for k in range(n)))
    return st


async def probe(c: httpx.AsyncClient, stop: asyncio.Event, rows: list, interval: float):
    """Fire every PROBES endpoint every `interval`, never waiting on a slow one,
    so a drained pool shows as errors/latency rather than a stalled probe."""

    async def hit(ep: str):
        t0 = time.time()
        try:
            r = await c.get(ep, timeout=15)
            s = r.status_code
        except httpx.HTTPError as e:
            s = type(e).__name__
        rows.append({"t": t0, "ep": ep, "status": s, "ms": (time.time() - t0) * 1000})

    tasks = []
    while not stop.is_set():
        tasks += [asyncio.create_task(hit(ep)) for ep in PROBES]
        await asyncio.sleep(interval)
    await asyncio.gather(*tasks)


async def burst(api: str, hdrs: dict, n: int, conc: int) -> list[dict]:
    """Fire the deletes over pre-opened raw sockets, all written in one loop pass.

    httpx at 400 in flight is CPU-bound in its pool: the first run's 400
    deletes reached the server spread over ~6 s (server time p50 396 ms, client
    p50 5 s), which is not the incident's shape. Raw HTTP/1.1 with
    `Connection: close` costs ~nothing per request, so the server really sees
    `conc` at once. Lanes past the first round open a fresh socket each."""
    u = urlsplit(api)
    tls = u.scheme == "https"
    port = u.port or (443 if tls else 80)
    extra = "".join(f"{h}: {v}\r\n" for h, v in hdrs.items())

    def req(k: int) -> bytes:
        return (
            f"DELETE {u.path}/attachments/{quote(path_of(k))} HTTP/1.1\r\n"
            f"Host: {u.netloc}\r\n{extra}Connection: close\r\nContent-Length: 0\r\n\r\n"
        ).encode()

    def connect():
        return asyncio.open_connection(
            u.hostname,
            port,
            ssl=True if tls else None,
            server_hostname=u.hostname if tls else None,
        )

    slots = await asyncio.gather(*(connect() for _ in range(min(conc, n))))
    go, rows = asyncio.Event(), []

    async def lane(i: int, conn):
        await go.wait()
        for k in range(i, n, len(slots)):
            t0 = time.time()
            try:
                r, w = conn or await connect()
                conn = None
                w.write(req(k))
                await w.drain()
                resp = await asyncio.wait_for(r.read(), 30)  # Connection: close, so EOF
                w.close()
                s = int(resp.split(b" ", 2)[1])
                if s != 200:  # 429 is both the rate limiter and #2356's SeqGate Busy
                    s = f"{s}:{error_code(resp)}"
            except asyncio.TimeoutError:
                s = "timeout"
            except (OSError, ValueError, IndexError) as e:
                s = type(e).__name__
            rows.append({"t": t0, "status": s, "ms": (time.time() - t0) * 1000})

    tasks = [asyncio.create_task(lane(i, c)) for i, c in enumerate(slots)]
    await asyncio.sleep(0.2)  # let every lane park on the event
    go.set()
    await asyncio.gather(*tasks)
    return rows


def error_code(resp: bytes) -> str:
    try:
        return json.loads(resp.split(b"\r\n\r\n", 1)[1]).get("error", "?")
    except (ValueError, IndexError, AttributeError):
        return "?"


def bucket(s) -> str:
    if isinstance(s, str):
        return s
    return str(s) if s in (200, 404, 429) else f"{s // 100}xx"


def phase_stats(rows: list[dict], lo: float, hi: float) -> dict:
    out = {}
    for ep in PROBES:
        rs = [r for r in rows if r["ep"] == ep and lo <= r["t"] < hi]
        ms = [r["ms"] for r in rs]
        out[ep] = {
            "n": len(rs),
            "errors": sum(1 for r in rs if r["status"] != 200),
            "status": dict(Counter(bucket(r["status"]) for r in rs)),
            "p50": pct(ms, 50),
            "p95": pct(ms, 95),
            "p99": pct(ms, 99),
            "max": round(max(ms), 1) if ms else None,
        }
    return out


def pool_errors(since: str, until: str) -> dict:
    r = ssh(
        f"docker logs --since {since} --until {until} {STAGING_APP} 2>&1", timeout=120
    )
    lines = r.stdout.splitlines()
    return {
        "connection_error": sum("DBConnection.ConnectionError" in ln for ln in lines),
        "dropped_from_queue": sum("dropped from queue" in ln for ln in lines),
        "sample": [
            redact(ln[:300]) for ln in lines if any(m in ln for m in POOL_ERRORS)
        ][:3],
    }


def iso(t: float) -> str:
    return datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


async def run(a, key: str, vault_id: str) -> dict:
    hdrs = {"Authorization": f"Bearer {key}", "X-Vault-ID": vault_id}
    async with httpx.AsyncClient(base_url=a.api, headers=hdrs, timeout=30) as c:
        health = (await c.get("/health")).json()
        t_seed = time.time()
        seeded = await seed(c, a.n, a.seed_rate)
        print(
            f"[delburst] seeded {dict(seeded)} in {time.time() - t_seed:.0f}s",
            flush=True,
        )
        t_seed_end = time.time()

    await asyncio.sleep(
        max(0.0, PREAUTH_WINDOW_S - a.baseline - (time.time() - t_seed_end))
    )

    # Probe on its own thread, loop and pool, so the burst cannot stall its
    # cadence client-side (it did when they shared a loop).
    rows, stop = [], threading.Event()

    async def probe_main():
        async with httpx.AsyncClient(base_url=a.api, headers=hdrs, timeout=15) as pc:
            await probe(pc, stop, rows, a.probe_interval)

    th = threading.Thread(target=asyncio.run, args=(probe_main(),))
    th.start()
    try:
        t0 = time.time()
        await asyncio.sleep(a.baseline)
        t1 = time.time()
        dels = await burst(a.api, hdrs, a.n, a.concurrency)
        t2 = time.time()
        await asyncio.sleep(a.tail)
    finally:
        stop.set()
        th.join()
    t3 = time.time()

    dms = [d["ms"] for d in dels]
    return {
        "api": a.api,
        "build": health,
        "n": a.n,
        "concurrency": a.concurrency,
        "seed_status": dict(seeded),
        "window": {
            "baseline_start": iso(t0),
            "burst_start": iso(t1),
            "burst_end": iso(t2),
            "end": iso(t3),
            "burst_seconds": round(t2 - t1, 2),
        },
        "deletes": {
            "status": dict(Counter(bucket(d["status"]) for d in dels)),
            "p50": pct(dms, 50),
            "p95": pct(dms, 95),
            "p99": pct(dms, 99),
            "max": round(max(dms), 1) if dms else None,
        },
        "probe": {
            "baseline": phase_stats(rows, t0, t1),
            "burst": phase_stats(rows, t1, t2),
            "tail": phase_stats(rows, t2, t3),
        },
        "_raw": {"deletes": dels, "probe": rows},
    }


def main() -> int:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument("--api", default=DEFAULT_API)
    p.add_argument(
        "--key-env",
        default="ENGRAM_DELBURST_KEY",
        help="env var holding a TEST user's API key; unset = throwaway user via rpc",
    )
    p.add_argument(
        "--vault-id",
        help="required with --key-env: the test vault to seed and delete in",
    )
    p.add_argument("-n", "--n", type=int, default=400)
    p.add_argument("--concurrency", type=int, default=400)
    p.add_argument(
        "--seed-rate", type=float, default=25, help="seed uploads per second"
    )
    p.add_argument("--baseline", type=float, default=30)
    p.add_argument("--tail", type=float, default=15)
    p.add_argument("--probe-interval", type=float, default=0.1)
    p.add_argument(
        "--no-server-logs",
        action="store_true",
        help="skip the SSH docker-logs pool-error grep",
    )
    p.add_argument("--out", type=Path, default=Path("delburst-out"))
    p.add_argument("--i-know-this-is-not-staging", action="store_true")
    a = p.parse_args()
    check_target(a.api, a.i_know_this_is_not_staging)
    a.out.mkdir(parents=True, exist_ok=True)

    key, user_id, key_id, vault_id = os.environ.get(a.key_env), None, None, a.vault_id
    if key and not vault_id:
        p.error("--vault-id is required with an existing key")
    run_id = f"delburst-{uuid.uuid4().hex[:8]}"
    try:
        if not key:
            user_id = create_user(run_id)
            grant_overrides(
                run_id
            )  # api_rps_cap 1000: the incident client was not API-key capped
            key, key_id = mint_key(user_id)
            vault_id = create_vault(user_id, run_id)
            print(f"[delburst] throwaway user {user_id} vault {vault_id}", flush=True)
        res = asyncio.run(run(a, key, vault_id))
        if not a.no_server_logs:
            w = res["window"]
            try:
                res["server_pool_errors"] = pool_errors(w["baseline_start"], w["end"])
            except (subprocess.SubprocessError, OSError) as e:
                res["server_pool_errors"] = {"error": str(e)[:200]}
    finally:
        if user_id:  # hard delete: key, attachments, blobs, vault, user
            print(f"[delburst] cleanup: {delete_user(user_id, key_id)}", flush=True)
        else:
            print(
                "[delburst] existing credential: DelBurst/ files the burst did not delete remain",
                flush=True,
            )

    raw = res.pop("_raw")
    (a.out / "raw.json").write_text(json.dumps(raw))
    (a.out / "summary.json").write_text(json.dumps(res, indent=2))
    print(json.dumps(res, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
