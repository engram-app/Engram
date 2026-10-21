"""Staging traffic simulator.

Drives a deployed Engram (staging by default) with a prod-shaped workload:
~20 Clerk test accounts whose vault sizes mirror prod's skew, plugin-style REST
push/pull, multi-page CRDT catch-up walks over the socket, MCP tool calls,
OAuth device-token refresh rotation, churn (rename / folder move / delete +
restore), a vault delete + purge mid-run, and (via crdt_load.ts, the headless
tier's real plugin engine) CRDT live edits from two devices.

Reuses e2e/helpers (ClerkClient, ClerkAuth) and e2e/headless (Replica); the
only new client is the ~30-line Phoenix push/reply loop in `ws_catchup_walk`.

    python3 e2e/load/sim.py --duration 7200            # full run
    python3 e2e/load/sim.py --seed-only                 # accounts + vaults only
    python3 e2e/load/sim.py --duration 600 --steady 3   # smoke

Env: STAGING_CLERK_SECRET_KEY (Clerk Backend API key of the target's instance),
ENGRAM_PLUGIN_SRC (plugin checkout, for the CRDT half; omit to skip it).
Output: <out>/ops.jsonl (one line per op), <out>/summary.json, <out>/summary.md.
See e2e/load/README.md for the one-time limit grant and the spend guard.
"""

from __future__ import annotations

import argparse
import base64
import json
import math
import os
import random
import signal
import subprocess
import sys
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import quote

HERE = Path(__file__).resolve().parent
E2E = HERE.parent
sys.path.insert(0, str(E2E))

import requests  # noqa: E402
from websockets.sync.client import connect as ws_connect  # noqa: E402

from helpers.clerk import ClerkClient  # noqa: E402
from load.guards import redact  # noqa: E402
from load.guards import (  # noqa: E402
    SpendGuard,
    check_clerk_key,
    check_target,
)
from helpers.clerk_auth import ClerkAuth  # noqa: E402

# --------------------------------------------------------------------------
# Workload shape
# --------------------------------------------------------------------------

# Notes per account. Prod (2026-10-20): p50=1, p90=70, p99=1158, max 10,000.
# One whale, three ~1k, the rest small. Index = account number.
VAULT_SIZES = [
    10_000,
    1_000,
    1_000,
    1_000,
    300,
    150,
    90,
    70,
    50,
    40,
    30,
    20,
    15,
    10,
    8,
    5,
    3,
    2,
    1,
    1,
]

# Ops per second at 1x. 1x = prod's 24h mean (2026-10-20 Grafana): 0.74 HTTP
# req/s (mcp POST 0.27, mcp GET 0.10, folders 0.06, manifest 0.045, attachments
# 0.034, oauth/token 0.016, refresh 0.011, tree 0.006) plus 1.75 WS frames/s.
RATES = {
    "rest_push": 0.05,
    "rest_pull": 0.05,
    "manifest": 0.045,
    "tree": 0.01,
    "folders_get": 0.03,
    "folder_create": 0.03,
    "attach_up": 0.015,
    "attach_get": 0.015,
    "ws_catchup_walk": 0.005,
    "rename": 0.01,
    "folder_move": 0.003,
    "delete_restore": 0.01,
    "mcp_search_notes": 0.08,
    "mcp_get_notes": 0.08,
    "mcp_write_note": 0.04,
    "mcp_edit_note": 0.04,
    "mcp_list_folder": 0.06,
    "mcp_list_tags": 0.04,
    "oauth_refresh": 0.011,
}
# CRDT ops per second per CRDT session at 1x (crdt_load.ts).
CRDT_RATES = {"burst": 0.01, "concurrent": 0.004, "closed": 0.01}
CRDT_ACCOUNTS = [
    4,
    5,
    6,
]  # small/medium vaults: each replica downloads its vault at boot
PURGE_ACCOUNT = (
    3  # a 1k vault, so the batched purge lasts long enough to race a restore
)

WORDS = (
    "alpha beta gamma delta engram vault note sync crdt index embed query river stone "
    "garden kernel socket ledger budget recipe travel meeting project draft review idea "
    "summary journal health sleep coffee build deploy release staging server client"
).split()


# --------------------------------------------------------------------------
# Deterministic corpus: same account + index -> same bytes on every run, so a
# re-run seeds nothing and the server's unchanged-content skips hold.
# --------------------------------------------------------------------------


def words(rng: random.Random, n: int) -> str:
    return " ".join(rng.choice(WORDS) for _ in range(n))


def note_path(acct: int, i: int) -> str:
    rng = random.Random(f"path:{acct}:{i}")
    depth = rng.choice([0, 1, 1, 2, 2, 3, 6])  # some deep trees
    parts = [f"{rng.choice(WORDS).title()}{rng.randint(0, 9)}" for _ in range(depth)]
    return "/".join([*parts, f"n{i:05d}.md"])


def note_body(acct: int, i: int, n: int) -> str:
    rng = random.Random(f"body:{acct}:{i}")
    out = []
    if rng.random() < 0.2:  # frontmatter-heavy
        out.append("---")
        out.append(f"title: {words(rng, 3)}")
        out.append(f"tags: [{', '.join(rng.sample(WORDS, 4))}]")
        out.extend(f"{k}: {words(rng, 2)}" for k in rng.sample(WORDS, 16))
        out.append(f"created: 2026-0{rng.randint(1, 9)}-1{rng.randint(0, 9)}")
        out.append("---")
    out.append(f"# {words(rng, 3).title()}")
    for _ in range(rng.randint(2, 6)):
        out.append(words(rng, rng.randint(20, 60)))
    if n > 1:
        links = rng.sample(range(n), min(3, n))
        out.append(
            " ".join(f"[[{Path(note_path(acct, j)).stem}]]" for j in links if j != i)
        )
    out.append(f"#{rng.choice(WORDS)} #{rng.choice(WORDS)}")
    return "\n\n".join(out) + "\n"


def special_notes(acct: int) -> dict[str, str]:
    """A few large notes (hundreds of KB) and one base64-image note."""
    if acct == 1:
        return {
            f"Large/big{k}.md": note_body(acct, 90_000 + k, 1) * 220 for k in range(3)
        }  # ~300 KB each
    if acct == 2:
        rng = random.Random("img")
        blob = base64.b64encode(
            bytes(rng.getrandbits(8) for _ in range(150_000))
        ).decode()
        return {
            "Large/inline-image.md": f"# Inline image\n\n![shot](data:image/png;base64,{blob})\n"
        }
    return {}


def attachment_bytes(acct: int, k: int) -> bytes:
    rng = random.Random(f"att:{acct}:{k}")
    png_head = base64.b64decode(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
    )
    return png_head + bytes(
        rng.getrandbits(8) for _ in range(rng.randint(20_000, 200_000))
    )


def n_attachments(n_notes: int) -> int:
    return 50 if n_notes >= 10_000 else 20 if n_notes >= 1_000 else 2


def est_tokens(text: str) -> int:
    # Rough: 4 chars/token; base64 data URIs are filtered before embedding.
    if "base64," in text:
        return 50
    return len(text) // 4


# --------------------------------------------------------------------------
# Metrics
# --------------------------------------------------------------------------


class Recorder:
    def __init__(self, path: Path):
        self.f = open(path, "a", buffering=1)
        self.lock = threading.Lock()
        self.move_lock = threading.Lock()

    def rec(
        self, op: str, ms: float, status: int | str, ok: bool, err: str = ""
    ) -> None:
        line = json.dumps(
            {
                "t": round(time.time(), 3),
                "op": op,
                "ms": round(ms),
                "status": status,
                "ok": ok,
                "err": redact(err)[:200],
            }
        )
        with self.lock:
            self.f.write(line + "\n")


def summarize(
    ops_files: list[Path], out: Path, windows: list[tuple[str, float, float]]
) -> dict:
    rows = []
    for p in ops_files:
        if p.exists():
            for line in p.read_text().splitlines():
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    pass

    def pct(xs, q):
        if not xs:
            return None
        xs = sorted(xs)
        return xs[min(len(xs) - 1, int(math.ceil(q * len(xs))) - 1)]

    summary = {}
    for wname, a, b in windows:
        by = {}
        for r in rows:
            if a <= r["t"] < b:
                by.setdefault(r["op"], []).append(r)
        summary[wname] = {
            op: {
                "n": len(rs),
                "rps": round(len(rs) / max(1.0, b - a), 3),
                "err": sum(1 for r in rs if not r["ok"]),
                "p50": pct([r["ms"] for r in rs], 0.50),
                "p95": pct([r["ms"] for r in rs], 0.95),
                "p99": pct([r["ms"] for r in rs], 0.99),
                "statuses": sorted({str(r.get("status")) for r in rs if not r["ok"]}),
                "errs": sorted({r.get("err", "")[:120] for r in rs if not r["ok"]})[:5],
            }
            for op, rs in sorted(by.items())
        }
    (out / "summary.json").write_text(json.dumps(summary, indent=1))
    md = []
    for wname, ops in summary.items():
        md.append(
            f"\n### {wname}\n\n| op | n | rps | err | p50 ms | p95 ms | p99 ms | error statuses |\n|---|---|---|---|---|---|---|---|"
        )
        for op, s in ops.items():
            md.append(
                f"| {op} | {s['n']} | {s['rps']} | {s['err']} | {s['p50']} | {s['p95']} | {s['p99']} | {' '.join(s['statuses'])} |"
            )
    (out / "summary.md").write_text("\n".join(md) + "\n")
    return summary


# --------------------------------------------------------------------------
# Accounts
# --------------------------------------------------------------------------


class Account:
    def __init__(self, idx: int, api: str, prefix: str):
        self.idx = idx
        self.api = api
        self.email = f"{prefix}-u{idx:02d}+clerk_test@example.com"
        self.n_notes = VAULT_SIZES[idx]
        self.key = ""
        self.key_id = ""
        self.user_id = ""
        self.vault_id = ""
        self.clerk_id = ""
        self.refresh = ""
        self.paused = threading.Event()  # set = account busy (purge), skip ops
        self.lock = threading.Lock()
        self.churn_moved: set[int] = set()
        self.folder_flip = False
        self.edit_flip = False
        self.client_id = f"{prefix}-u{idx:02d}"

    def s(self, vault: bool = True) -> requests.Session:
        sess = requests.Session()
        sess.headers["Authorization"] = f"Bearer {self.key}"
        if vault:
            sess.headers["X-Vault-ID"] = self.vault_id
        return sess


def legal_manifest() -> dict:
    return json.loads((E2E.parent / "priv/legal/legal-manifest.json").read_text())


def provision(acct: Account, clerk: ClerkClient, run_id: str) -> None:
    acct.clerk_id = clerk.find_user_by_email(acct.email) or clerk.create_user(
        acct.email, uuid.uuid4().hex + "Aa1!"
    )
    j = requests.Session()
    j.auth = ClerkAuth(clerk, acct.clerk_id)
    r = j.post(f"{acct.api}/api-keys", json={"name": f"load-sim-{run_id}"}, timeout=30)
    r.raise_for_status()
    acct.key = r.json()["key"]
    # Revoke this account's keys from earlier runs (keys are unrecoverable, so
    # each run mints one; without this they pile up).
    for k in j.get(f"{acct.api}/api-keys", timeout=30).json().get("keys", []):
        if k["name"].startswith("load-sim-") and k["name"] != f"load-sim-{run_id}":
            j.delete(f"{acct.api}/api-keys/{k['id']}", timeout=30)
        elif k["name"] == f"load-sim-{run_id}":
            acct.key_id = k["id"]
    j.patch(
        f"{acct.api}/onboarding/profile",
        json={"uses_obsidian": True, "tools": ["claude"]},
        timeout=30,
    )
    st = j.get(f"{acct.api}/onboarding/status", timeout=30).json()
    tv, pv = st.get("current_tos_version"), st.get("current_privacy_version")
    man = legal_manifest()
    if tv and pv and tv in man["terms_of_service"] and pv in man["privacy_policy"]:
        j.post(
            f"{acct.api}/onboarding/accept-terms",
            json={
                "tos_version": tv,
                "tos_hash": man["terms_of_service"][tv],
                "privacy_version": pv,
                "privacy_hash": man["privacy_policy"][pv],
            },
            timeout=30,
        )
    # Reuse the account's live vault (it may be the one a purge cycle re-created).
    vaults = (
        acct.s(vault=False)
        .get(f"{acct.api}/vaults", timeout=30)
        .json()
        .get("vaults", [])
    )
    if vaults:
        acct.vault_id = vaults[0]["id"]
    else:
        r = requests.post(
            f"{acct.api}/vaults/register",
            json={"name": acct.client_id, "client_id": acct.client_id},
            headers={"Authorization": f"Bearer {acct.key}"},
            timeout=30,
        )
        r.raise_for_status()
        acct.vault_id = r.json().get("id") or r.json().get("vault", {}).get("id")
    acct.user_id = (
        acct.s(vault=False).get(f"{acct.api}/me", timeout=30).json()["user"]["id"]
    )
    revoke_device_families(acct, clerk)  # families a crashed earlier run left behind
    # OAuth device family for refresh rotation. /auth/device* shares a
    # 10/min per-IP bucket (rate_limit_auth), so pace and retry.
    d = post_retry(
        requests.Session(),
        f"{acct.api}/auth/device",
        {"client_id": "engram-obsidian"},
        timeout=30,
    ).json()
    if "user_code" not in d:
        return
    ra = j.post(
        f"{acct.api}/auth/device/authorize",
        json={"user_code": d["user_code"], "vault_id": acct.vault_id},
        timeout=30,
    )
    if ra.status_code == 200:
        t = post_retry(
            requests.Session(),
            f"{acct.api}/auth/device/token",
            {"device_code": d["device_code"], "platform": "desktop"},
            timeout=30,
        ).json()
        acct.refresh = t.get("refresh_token", "")


def revoke_device_families(acct: Account, clerk: ClerkClient) -> int:
    """Revoke every Obsidian device family on the account (the sim mints one per run)."""
    j = requests.Session()
    j.auth = ClerkAuth(clerk, acct.clerk_id)
    n = 0
    r = j.get(f"{acct.api}/connections", timeout=30)
    for c in r.json() if r.ok else []:
        if c.get("kind") == "obsidian" and c.get("family_id"):
            n += j.delete(
                f"{acct.api}/connections/device/{c['family_id']}", timeout=30
            ).ok
    return n


def post_retry(
    sess: requests.Session, url: str, payload: dict, timeout: int = 60, tries: int = 12
) -> requests.Response:
    for n in range(tries):
        r = sess.post(url, json=payload, timeout=timeout)
        if r.status_code != 429:
            return r
        time.sleep(float(r.headers.get("retry-after") or min(2**n, 10)))
    return r


def plan_seed(acct: Account) -> tuple[list, list, int]:
    """What the manifest lacks: (notes todo, attachments todo, est. embed tokens)."""
    s = acct.s()
    man = s.get(f"{acct.api}/sync/manifest", timeout=120).json()
    have = {n.get("path") for n in man.get("notes", [])}
    have_att = {a.get("path") for a in man.get("attachments", [])}
    want = {note_path(acct.idx, i): (i, None) for i in range(acct.n_notes)}
    for p, body in special_notes(acct.idx).items():
        want[p] = (-1, body)
    for k in range(10):  # churn set: renamed / deleted / restored during the run
        want[f"Churn/c{k}.md"] = (
            -1,
            f"# churn {k}\n\nstable churn body {k} for the load sim.\n",
        )
    for k in range(5):
        want[f"Churn/F1/m{k}.md"] = (-1, f"# moving {k}\n\nfolder-move body {k}.\n")
    # Churn notes move between two homes; a note sitting in its other home is
    # present, and re-seeding it would make the next move a 409 (target taken).
    for k in range(10):
        if f"Churn/Moved/c{k}.md" in have:
            want.pop(f"Churn/c{k}.md", None)
            acct.churn_moved.add(k)
    if any(p.startswith("Churn/F2/") for p in have):
        for k in range(5):
            want.pop(f"Churn/F1/m{k}.md", None)
        acct.folder_flip = True
    todo = [
        (p, b if b is not None else note_body(acct.idx, i, acct.n_notes))
        for p, (i, b) in want.items()
        if p not in have
    ]
    atts = [
        k
        for k in range(n_attachments(acct.n_notes))
        if f"Attachments/a{k:03d}.png" not in have_att
    ]
    return todo, atts, sum(est_tokens(b) for _, b in todo)


def seed(
    acct: Account, rec: Recorder, guard: SpendGuard, plan: tuple | None = None
) -> int:
    """Idempotent: writes only what the manifest lacks, each note only if the
    spend guard has room for it. Returns est. embed tokens written."""
    s = acct.s()
    todo, atts, _ = plan or plan_seed(acct)

    def put(item):
        p, body = item
        if not guard.take(est_tokens(body)):
            rec.rec(
                "seed_note",
                0,
                "spend_cap",
                False,
                "spend guard: cap reached, not written",
            )
            return 0
        t0 = time.time()
        r = post_retry(
            s, f"{acct.api}/notes", {"path": p, "content": body, "mtime": time.time()}
        )
        rec.rec(
            "seed_note",
            (time.time() - t0) * 1000,
            r.status_code,
            r.ok,
            "" if r.ok else r.text,
        )
        return est_tokens(body) if r.ok else 0

    with ThreadPoolExecutor(6) as ex:
        tokens = sum(ex.map(put, todo))
    for k in atts:
        p = f"Attachments/a{k:03d}.png"
        t0 = time.time()
        r = post_retry(
            s,
            f"{acct.api}/attachments",
            {
                "path": p,
                "content_base64": base64.b64encode(
                    attachment_bytes(acct.idx, k)
                ).decode(),
                "mtime": time.time(),
            },
        )
        rec.rec(
            "seed_attachment",
            (time.time() - t0) * 1000,
            r.status_code,
            r.ok,
            "" if r.ok else r.text,
        )
    return tokens


def estimate_seed_tokens(prefix_existing: dict[int, set] | None = None) -> int:
    total = 0
    for idx, n in enumerate(VAULT_SIZES):
        total += sum(est_tokens(note_body(idx, i, n)) for i in range(n))
        total += sum(est_tokens(b) for b in special_notes(idx).values())
    return total


# --------------------------------------------------------------------------
# Ops
# --------------------------------------------------------------------------


def pick(accts: list[Account], rng: random.Random) -> Account:
    live = [a for a in accts if not a.paused.is_set()]
    w = [1 + math.log10(a.n_notes) for a in live]  # bigger vaults are busier
    return rng.choices(live, weights=w)[0]


def mcp(acct: Account, name: str, args: dict) -> requests.Response:
    return acct.s(vault=False).post(
        f"{acct.api}/mcp",
        json={
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": name, "arguments": {"vault_id": acct.vault_id, **args}},
        },
        timeout=90,
    )


def mcp_ok(r: requests.Response) -> tuple[bool, str]:
    if r.status_code != 200:
        return False, r.text[:200]
    b = r.json()
    if "error" in b or b.get("result", {}).get("isError"):
        return False, json.dumps(b)[:200]
    return True, ""


def ws_catchup_walk(
    acct: Account, ws_url: str, rec: Recorder, limit: int = 500
) -> tuple[bool, str]:
    """Phoenix V2 push/reply loop: walk crdt_catchup_since until has_more=false."""
    url = f"{ws_url}?vsn=2.0.0&token={acct.key}&device_id=load-walk-{acct.idx}&plugin_version=1.36.1"
    with ws_connect(
        url,
        origin=ws_url.replace("wss://", "https://").split("/socket")[0],
        max_size=50_000_000,
        open_timeout=30,
    ) as ws:
        ref = 0

        def push(topic, event, payload):
            nonlocal ref
            ref += 1
            ws.send(json.dumps(["1", str(ref), topic, event, payload]))
            deadline = time.time() + 120
            while time.time() < deadline:
                m = json.loads(ws.recv(timeout=120))
                if m[1] == str(ref) and m[3] == "phx_reply":
                    return m[4]
            raise TimeoutError(event)

        topic = f"crdt:{acct.user_id}:{acct.vault_id}"
        j = push(topic, "phx_join", {"crdt_proto": 2, "client_type": "load-sim"})
        if j.get("status") != "ok":
            return False, f"join {json.dumps(j)[:150]}"
        seq, cid, rows, pages, seen = 0, None, 0, 0, set()
        while True:
            t0 = time.time()
            payload = {
                "cursor_seq": seq,
                "limit": limit,
                **({"cursor_id": cid} if cid else {}),
            }
            r = push(topic, "crdt_catchup_since", payload)
            ok = r.get("status") == "ok"
            rec.rec(
                "ws_catchup_page",
                (time.time() - t0) * 1000,
                r.get("status"),
                ok,
                "" if ok else json.dumps(r)[:200],
            )
            if not ok:
                return False, "page refused"
            resp = r["response"]
            pages += 1
            for c in resp["changes"]:
                k = (c.get("type"), c.get("id"))
                if k in seen:
                    return False, f"duplicate row {k} on page {pages}"
                seen.add(k)
            rows += len(resp["changes"])
            if not resp["has_more"]:
                break
            seq, cid = resp["next_seq"], resp["next_id"]
        notes = sum(1 for t, _ in seen if t == "note")
        if notes < acct.n_notes:
            return False, f"walk saw {notes} note rows < {acct.n_notes} seeded"
        return True, f"pages={pages} rows={rows}"


# Embed tokens one op writes (est_tokens of its bodies). Only content writes
# embed; attachments and moves do not.
WRITE_TOKENS = {
    "rest_push": 20,
    "delete_restore": 40,
    "mcp_write_note": 20,
    "mcp_edit_note": 15,
}


def run_op(op: str, acct: Account, rng: random.Random, args, rec: Recorder) -> None:
    if op in WRITE_TOKENS and not args.guard.take(WRITE_TOKENS[op]):
        rec.rec(op, 0, "spend_cap", False, "spend guard: cap reached, not sent")
        return
    s = acct.s()
    api = acct.api
    t0 = time.time()
    status: int | str = 0
    ok, err = False, ""
    try:
        if op == "rest_push":
            k = rng.randrange(10)
            with acct.lock:
                moved = k in acct.churn_moved
                acct.edit_flip = not acct.edit_flip
                v = acct.edit_flip
            p = f"Churn/Moved/c{k}.md" if moved else f"Churn/c{k}.md"
            body = f"# churn {k}\n\nstable churn body {k} for the load sim.\n" + (
                "variant B\n" if v else ""
            )
            r = post_retry(
                s, f"{api}/notes", {"path": p, "content": body, "mtime": time.time()}
            )
            status, ok = r.status_code, r.ok
        elif op == "rest_pull":
            i = rng.randrange(acct.n_notes)
            r = s.get(
                f"{api}/notes/{quote(note_path(acct.idx, i), safe='')}", timeout=60
            )
            status, ok = r.status_code, r.status_code == 200
        elif op == "manifest":
            r = s.get(f"{api}/sync/manifest", timeout=120)
            status, ok = r.status_code, r.ok
        elif op == "tree":
            r = s.get(f"{api}/vault/tree", timeout=120)
            status, ok = r.status_code, r.ok
        elif op == "folders_get":
            r = s.get(f"{api}/folders", timeout=60)
            status, ok = r.status_code, r.ok
        elif op == "folder_create":
            r = post_retry(
                s, f"{api}/folders", {"folder": f"Empty/e{rng.randrange(20)}"}
            )
            status, ok = r.status_code, r.status_code in (200, 201, 409)
        elif op == "attach_up":
            k = rng.randrange(n_attachments(acct.n_notes))
            r = post_retry(
                s,
                f"{api}/attachments",
                {
                    "path": f"Attachments/a{k:03d}.png",
                    "content_base64": base64.b64encode(
                        attachment_bytes(acct.idx, k)
                    ).decode(),
                    "mtime": time.time(),
                },
            )
            status, ok = r.status_code, r.ok
        elif op == "attach_get":
            k = rng.randrange(n_attachments(acct.n_notes))
            r = s.get(
                f"{api}/attachments/{quote(f'Attachments/a{k:03d}.png', safe='')}",
                timeout=60,
            )
            status, ok = r.status_code, r.status_code == 200 and len(r.content) > 20_000
        elif op == "ws_catchup_walk":
            ok, err = ws_catchup_walk(acct, args.ws, rec)
            status = "ok" if ok else "fail"
        elif op == "rename":
            # Serialized per account: two in-flight moves of one note race each
            # other into a 409 that is the harness's, not the server's.
            k = rng.randrange(10)
            with acct.move_lock:
                moved = k in acct.churn_moved
                a, b = (
                    (f"Churn/Moved/c{k}.md", f"Churn/c{k}.md")
                    if moved
                    else (f"Churn/c{k}.md", f"Churn/Moved/c{k}.md")
                )
                r = post_retry(s, f"{api}/notes/rename", {"old_path": a, "new_path": b})
                status, ok = r.status_code, r.status_code == 200
                if ok:
                    (acct.churn_moved.discard if moved else acct.churn_moved.add)(k)
                else:
                    err = f"{a} -> {b}: {r.text[:150]}"
        elif op == "folder_move":
            with acct.move_lock:
                a, b = (
                    ("Churn/F2", "Churn/F1")
                    if acct.folder_flip
                    else ("Churn/F1", "Churn/F2")
                )
                r = post_retry(
                    s, f"{api}/folders/rename", {"old_path": a, "new_path": b}
                )
                status, ok = r.status_code, r.status_code == 200
                if ok:
                    acct.folder_flip = not acct.folder_flip
                else:
                    err = f"{a} -> {b}: {r.text[:150]}"
        elif op == "delete_restore":
            # Restore with different bytes: re-pushing the exact content of a
            # just-deleted note is refused by design (409 recently_deleted, the
            # stale-device resurrection guard). Two variants keep the embed cache warm.
            p = f"Churn/dr{rng.randrange(3)}.md"
            base = "# delete and restore\n\nthis note is deleted then restored by the load sim.\n"
            r1 = post_retry(
                s, f"{api}/notes", {"path": p, "content": base, "mtime": time.time()}
            )
            r2 = s.delete(f"{api}/notes/{quote(p, safe='')}", timeout=60)
            r3 = post_retry(
                s,
                f"{api}/notes",
                {"path": p, "content": base + "restored\n", "mtime": time.time()},
            )
            r4 = s.get(f"{api}/notes/{quote(p, safe='')}", timeout=60)
            status = (
                f"{r1.status_code}/{r2.status_code}/{r3.status_code}/{r4.status_code}"
            )
            ok = (
                r1.ok
                and r2.status_code in (200, 204)
                and r3.ok
                and r4.status_code == 200
            )
        elif op.startswith("mcp_"):
            name = op[4:]
            if name == "search_notes":
                args_ = {"query": " ".join(rng.sample(WORDS, 3)), "limit": 5}
            elif name == "get_notes":
                args_ = {
                    "paths": [
                        note_path(acct.idx, rng.randrange(acct.n_notes))
                        for _ in range(min(3, acct.n_notes))
                    ]
                }
            elif name == "write_note":
                k = rng.randrange(3)
                args_ = {
                    "path": f"Churn/mcp{k}.md",
                    "content": f"# mcp {k}\n\nwritten by mcp {rng.choice(['A', 'B'])}.\n\n## Todo\n- item\n",
                }
            elif name == "edit_note":
                k = rng.randrange(3)
                post_retry(
                    s,
                    f"{api}/notes",
                    {
                        "path": f"Churn/mcpe{k}.md",
                        "content": f"# mcpe {k}\n\nstate alpha\n",
                        "mtime": time.time(),
                    },
                ) if rng.random() < 0.05 else None
                a, b = rng.choice([("alpha", "omega"), ("omega", "alpha")])
                args_ = {
                    "path": f"Churn/mcpe{k}.md",
                    "mode": "replace_text",
                    "find": f"state {a}",
                    "replace": f"state {b}",
                }
            elif name == "list_folder":
                args_ = {"folder": rng.choice(["Churn", "Attachments", "Large", ""])}
            else:
                args_ = {}
            r = mcp(acct, name, args_)
            status = r.status_code
            ok, err = mcp_ok(r)
            if not ok and name == "edit_note" and "not found" in err.lower():
                # The target was never created yet or the find text is the other state: not a server fault.
                ok, status = True, "edit_miss"
            if (
                not ok
                and name == "edit_note"
                and (
                    "no match" in err.lower()
                    or "not find" in err.lower()
                    or "0 replacements" in err.lower()
                    or "expected" in err.lower()
                )
            ):
                ok, status = True, "edit_miss"
        elif op == "oauth_refresh":
            with acct.lock:
                rt = acct.refresh
            if not rt:
                ok, status, err = True, "no_family", ""
            else:
                r = requests.post(
                    f"{api}/auth/token/refresh", json={"refresh_token": rt}, timeout=30
                )
                status, ok = r.status_code, r.status_code == 200
                if ok:
                    with acct.lock:
                        acct.refresh = r.json().get("refresh_token", "")
                else:
                    err = r.text[:200]
        if not ok and not err:
            err = f"status {status}"
    except Exception as e:  # recorded as a failed op; the run keeps going
        ok, err, status = False, f"{type(e).__name__}: {e}", "exc"
    rec.rec(op, (time.time() - t0) * 1000, status, ok, err)


def mult(t: float, a) -> float:
    if t < a.warmup:
        return 1 + (a.steady - 1) * t / a.warmup
    if a.burst_at <= t < a.burst_at + a.burst_len:
        return a.burst
    return a.steady


def purge_cycle(
    acct: Account, clerk: ClerkClient, rec: Recorder, guard: SpendGuard
) -> None:
    """Delete + purge one vault mid-run, check restore is refused, re-create it."""
    acct.paused.set()
    try:
        s = acct.s(vault=False)
        t0 = time.time()
        r = s.delete(f"{acct.api}/vaults/{acct.vault_id}", timeout=60)
        rec.rec(
            "vault_delete",
            (time.time() - t0) * 1000,
            r.status_code,
            r.ok,
            "" if r.ok else r.text,
        )
        j = requests.Session()
        j.auth = ClerkAuth(clerk, acct.clerk_id)
        t0 = time.time()
        r = j.post(f"{acct.api}/vaults/{acct.vault_id}/purge", timeout=60)
        rec.rec(
            "vault_purge",
            (time.time() - t0) * 1000,
            r.status_code,
            r.ok,
            "" if r.ok else r.text,
        )
        # Poll restore: 409 purge_started while the batches run, then 404 once gone.
        seen = []
        t0 = time.time()
        while time.time() - t0 < 900:
            rr = s.post(f"{acct.api}/vaults/{acct.vault_id}/restore", timeout=60)
            if not seen or seen[-1] != rr.status_code:
                seen.append(rr.status_code)
            if rr.status_code == 200:
                # Restore won the race before purge_started_at was stamped; the
                # purge job then no-ops. Valid, but delete again so it purges.
                s.delete(f"{acct.api}/vaults/{acct.vault_id}", timeout=60)
                j.post(f"{acct.api}/vaults/{acct.vault_id}/purge", timeout=60)
            if rr.status_code == 404:
                break
            time.sleep(0.2)
        ok = bool(seen) and seen[-1] == 404
        rec.rec(
            "vault_purge_complete",
            (time.time() - t0) * 1000,
            "->".join(map(str, seen)),
            ok,
            "" if ok else f"restore statuses {seen}",
        )
        # Did a restore land inside the purge window and get refused? (informational)
        rec.rec(
            "vault_restore_refused_409", 0, "seen" if 409 in seen else "not_seen", True
        )
        # Fresh vault for the rest of the run and the next one.
        acct.client_id = f"{acct.client_id.split('~')[0]}~{uuid.uuid4().hex[:6]}"
        r = requests.post(
            f"{acct.api}/vaults/register",
            json={"name": acct.client_id, "client_id": acct.client_id},
            headers={"Authorization": f"Bearer {acct.key}"},
            timeout=30,
        )
        acct.vault_id = r.json().get("id") or r.json().get("vault", {}).get("id")
        seed(acct, rec, guard)
    finally:
        acct.paused.clear()


_CHILDREN: list[subprocess.Popen] = []


def spawn_child(
    cmd: list[str], cfg: dict, env: dict | None, log: Path
) -> subprocess.Popen:
    """Start the CRDT child with its config (live API keys) on STDIN, so no key
    file ever exists, not even one a SIGTERM would strand."""
    child = subprocess.Popen(
        cmd,
        env=env,
        stdin=subprocess.PIPE,
        stdout=open(log, "w"),
        stderr=subprocess.STDOUT,
        text=True,
    )
    _CHILDREN.append(child)
    child.stdin.write(json.dumps(cfg))
    child.stdin.close()
    return child


def install_signal_handlers() -> None:
    """SIGTERM/SIGINT (a CI cancel or timeout): stop the children, exit 128+sig.
    atexit alone does not run on a signal, which orphaned the bun child."""

    def on_signal(signum, _frame):
        for c in _CHILDREN:
            if c.poll() is None:
                c.terminate()
        for c in _CHILDREN:
            try:
                c.wait(timeout=10)
            except subprocess.TimeoutExpired:
                c.kill()
        os._exit(128 + signum)

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)


def main() -> int:
    ap = argparse.ArgumentParser()
    # Deliberately NOT defaulted from ENGRAM_API_URL: the headless e2e harness
    # reads that variable, and a stray export must not pick the load target.
    ap.add_argument("--api", default="https://staging.engram.page/api")
    ap.add_argument(
        "--i-know-this-is-not-staging",
        dest="allow_any_host",
        action="store_true",
        help="allow a target outside the staging allowlist (never prod)",
    )
    ap.add_argument(
        "--prefix", default="load-sim", help="account email prefix; stable across runs"
    )
    ap.add_argument("--accounts", type=int, default=len(VAULT_SIZES))
    ap.add_argument("--duration", type=int, default=7200)
    ap.add_argument("--warmup", type=int, default=600)
    ap.add_argument("--steady", type=float, default=10)
    ap.add_argument("--burst", type=float, default=30)
    ap.add_argument("--burst-at", type=int, default=3600)
    ap.add_argument("--burst-len", type=int, default=300)
    ap.add_argument("--purge-at", type=int, default=2700)
    ap.add_argument(
        "--max-seed-tokens",
        type=int,
        default=12_000_000,
        help="spend guard: refuse to start a seed whose missing notes estimate more than this",
    )
    ap.add_argument(
        "--max-embed-tokens",
        type=int,
        default=20_000_000,
        help="spend guard: running cap on est. embed tokens for the whole run (seed, purge re-seed, traffic)",
    )
    ap.add_argument("--seed-only", action="store_true")
    ap.add_argument(
        "--provision-only",
        action="store_true",
        help="create accounts + vaults, then stop (apply grant.sql next)",
    )
    ap.add_argument("--no-crdt", action="store_true")
    ap.add_argument("--workers", type=int, default=24)
    ap.add_argument("--out", default=os.environ.get("LOAD_OUT", "load-out"))
    args = ap.parse_args()
    install_signal_handlers()
    check_target(args.api, args.allow_any_host)
    clerk_key = os.environ.get("STAGING_CLERK_SECRET_KEY", "")
    check_clerk_key(clerk_key)
    args.guard = SpendGuard(args.max_embed_tokens)
    args.ws = (
        args.api.replace("https://", "wss://")
        .replace("http://", "ws://")
        .removesuffix("/api")
        + "/socket/websocket"
    )
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    rec = Recorder(out / "ops.jsonl")
    run_id = time.strftime("%Y%m%d%H%M%S")
    clerk = ClerkClient(clerk_key)

    accts = [Account(i, args.api, args.prefix) for i in range(args.accounts)]
    with ThreadPoolExecutor(5) as ex:
        list(ex.map(lambda a: provision(a, clerk, run_id), accts))
    print(f"[sim] provisioned {len(accts)} accounts", flush=True)
    (out / "accounts.json").write_text(
        json.dumps(
            [
                {
                    "idx": a.idx,
                    "email": a.email,
                    "user_id": a.user_id,
                    "vault_id": a.vault_id,
                    "notes": a.n_notes,
                }
                for a in accts
            ],
            indent=1,
        )
    )

    if args.provision_only:
        return 0
    # Spend guard, BEFORE anything is written: estimate only what is missing.
    with ThreadPoolExecutor(4) as ex:
        plans = dict(zip([a.idx for a in accts], ex.map(plan_seed, accts)))
    missing = sum(p[2] for p in plans.values())
    print(
        f"[sim] seed needs ~{missing / 1e6:.2f}M est embed tokens "
        f"(full corpus {estimate_seed_tokens() / 1e6:.2f}M; cap {args.max_seed_tokens / 1e6:.1f}M)",
        flush=True,
    )
    if missing > args.max_seed_tokens:
        print(
            "[sim] spend guard: seed estimate over --max-seed-tokens, nothing written",
            flush=True,
        )
        return 2
    t0 = time.time()
    with ThreadPoolExecutor(4) as ex:
        seeded = sum(
            ex.map(
                lambda a: seed(a, rec, args.guard, plans[a.idx]),
                sorted(accts, key=lambda a: -a.n_notes),
            )
        )
    print(
        f"[sim] seeded ~{seeded / 1e6:.2f}M est tokens in {time.time() - t0:.0f}s",
        flush=True,
    )
    if args.seed_only:
        return 0

    start = time.time()
    end = start + args.duration
    crdt = None
    plugin = os.environ.get("ENGRAM_PLUGIN_SRC")
    if plugin and not args.no_crdt:
        cfg = {
            "sessions": [
                {
                    "token": accts[i].key,
                    "userId": accts[i].user_id,
                    "vaultId": accts[i].vault_id,
                    "label": f"u{i:02d}",
                }
                for i in CRDT_ACCOUNTS
                if i < len(accts)
            ],
            "start": start,
            "schedule": {
                "warmup": args.warmup,
                "steady": args.steady,
                "burst": args.burst,
                "burstAt": args.burst_at,
                "burstLen": args.burst_len,
                "duration": args.duration,
            },
            "rates": CRDT_RATES,
            "out": str((out / "crdt_ops.jsonl").resolve()),
            "apiUrl": args.api,
        }
        # The config carries live API keys: it goes to bun on STDIN, never to a
        # file (see spawn_child), and never into --out (CI uploads that).
        # The plugin code bun imports comes from another repo's ref: it gets no Clerk key.
        env = {k: v for k, v in os.environ.items() if k != "STAGING_CLERK_SECRET_KEY"}
        env.update(ENGRAM_API_URL=args.api, E2E_DELIVERY_TIMEOUT="60")
        crdt = spawn_child(
            [
                "bun",
                "--preload",
                str(E2E / "headless/preload.ts"),
                str(HERE / "crdt_load.ts"),
                "-",
            ],
            cfg,
            env=env,
            log=out / "crdt.log",
        )

    pool = ThreadPoolExecutor(args.workers)
    inflight = threading.Semaphore(
        args.workers * 4
    )  # never queue unboundedly behind a slow server
    stop = threading.Event()

    def driver(op: str, base: float) -> None:
        rng = random.Random(f"{op}:{run_id}")
        while not stop.is_set():
            t = time.time() - start
            rate = base * mult(t, args)
            if op == "oauth_refresh":
                rate = min(
                    rate, 0.12
                )  # /auth/token/refresh shares a 10/min per-IP bucket; one sim = one IP
            stop.wait(min(30.0, rng.expovariate(rate)))
            if stop.is_set() or time.time() >= end:
                return
            if not inflight.acquire(blocking=False):
                rec.rec(op, 0, "client_backlog", False, "client in-flight cap reached")
                continue
            acct = pick(accts, rng)
            if op == "ws_catchup_walk" and acct.idx in CRDT_ACCOUNTS:
                inflight.release()
                continue

            def go(o=op, a=acct, r=random.Random(rng.random())):
                try:
                    run_op(o, a, r, args, rec)
                finally:
                    inflight.release()

            pool.submit(go)

    threads = [
        threading.Thread(target=driver, args=(op, r), daemon=True)
        for op, r in RATES.items()
    ]
    for th in threads:
        th.start()
    purge_acct = accts[PURGE_ACCOUNT] if PURGE_ACCOUNT < len(accts) else None
    purge_th = None
    last = 0.0
    while time.time() < end:
        time.sleep(5)
        t = time.time() - start
        if purge_acct and purge_th is None and t >= args.purge_at:
            purge_th = threading.Thread(
                target=purge_cycle,
                args=(purge_acct, clerk, rec, args.guard),
                daemon=True,
            )
            purge_th.start()
        if t - last >= 300:
            last = t
            print(f"[sim] t={t:.0f}s mult={mult(t, args):.1f}", flush=True)
    stop.set()
    pool.shutdown(wait=True)
    if purge_th:
        purge_th.join(timeout=900)
    if crdt:
        try:
            crdt.wait(timeout=600)
        except subprocess.TimeoutExpired:
            crdt.kill()
    for a in accts:  # don't leave this run's device families live
        revoke_device_families(a, clerk)
    a = args
    windows = [
        ("all", start, end + 600),
        ("warmup", start, start + a.warmup),
        ("steady", start + a.warmup, start + a.burst_at),
        ("burst", start + a.burst_at, start + a.burst_at + a.burst_len),
        ("after-burst", start + a.burst_at + a.burst_len, end + 600),
    ]
    summary = summarize([out / "ops.jsonl", out / "crdt_ops.jsonl"], out, windows)
    allw = summary["all"]
    total = sum(s["n"] for s in allw.values())
    errs = sum(s["err"] for s in allw.values())
    print(
        f"[sim] done: {total} ops, {errs} errors ({100 * errs / max(1, total):.2f}%)",
        flush=True,
    )
    print((out / "summary.md").read_text(), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
