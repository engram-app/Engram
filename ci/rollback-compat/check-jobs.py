#!/usr/bin/env python3
"""Phase 3 of rollback-compat.yml: OLD's background jobs that failed on NEW's data.

Every OLD job that ended retryable, discarded or cancelled during phase 3
fails the run unless the pair's jobs-allow.txt names its worker AND an error
kind that this job's own evidence shows. Evidence is the job's last error text
plus every log line naming one of its args values (EmbedNote's
`embed_attempt_failed` carries the note id and `error_kind`). Every
`Oban job attempt failed` / `discarded` log line must belong to an allowed
job. Allowlist lines no job used are flagged.

Usage: check-jobs.py JOBS_JSON ALLOWLIST SHAPE LOG...
Allowlist: <shape|*> <worker> <error kind> <reason>
"""

from __future__ import annotations

import json
import re
import sys


def main() -> int:
    jobs_path, allow_path, shape, *logs = sys.argv[1:]
    jobs = json.load(open(jobs_path))
    lines = [ln for p in logs for ln in open(p, errors="replace")]
    allow = []
    try:
        for raw in open(allow_path):
            parts = raw.split(None, 3)
            if len(parts) == 4 and not raw.startswith("#") and parts[0] in (shape, "*"):
                allow.append({"worker": parts[1], "kind": parts[2], "reason": parts[3].strip(), "used": 0})
    except FileNotFoundError:
        pass

    bad, ok_ids = [], set()
    for job in jobs:
        values = [str(v) for v in (job.get("args") or {}).values() if isinstance(v, (str, int)) and len(str(v)) >= 8]
        evidence = (job.get("error") or "") + "".join(ln for ln in lines if any(v in ln for v in values))
        hit = next((a for a in allow if a["worker"] == job["worker"] and a["kind"] in evidence), None)
        first = (job.get("error") or "").strip().splitlines()[:1]
        if hit:
            hit["used"] += 1
            ok_ids.add(int(job["id"]))
            print(f"  job {job['id']} {job['worker']} {job['state']}: allowed ({hit['kind']}: {hit['reason']})")
        else:
            bad.append(f"OLD job {job['id']} {job['worker']} ended {job['state']}: {first[0] if first else 'no error text'}")

    for ln in lines:
        if re.search(r"Oban job (attempt failed|discarded)", ln):
            m = re.search(r"job_id=(\d+)", ln)
            if not m or int(m.group(1)) not in ok_ids:
                bad.append(f"Oban failure line for a job not allowed: {ln.strip()[:200]}")

    for a in allow:
        if not a["used"]:
            print(f"::warning::unused jobs-allow line: {a['worker']} {a['kind']} ({a['reason']})")
    print(f"failed OLD jobs in phase 3: {len(jobs)}, allowed: {len(ok_ids)}")
    for b in bad:
        print(f"::error::{b}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
