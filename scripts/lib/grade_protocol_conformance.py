#!/usr/bin/env python3
"""Grade one `mcpjam protocol conformance` run.

Unlike the OAuth stage, this one CAN complete — given a bearer token. So the bar
is the strict one: every check must actually run and pass.

**A skipped check is a failure here.** Without a token 29 of 32 checks skip, and
the CLI still emits a tidy report; treating that as anything but red is how a
suite comes to certify work it never did. Skips are therefore listed by name so
the reason is visible rather than inferred.

Usage: grade_protocol_conformance.py <results.json> <label>
Exit 0 = every check ran and passed. Exit 1 = anything else.
"""

import json
import sys


def collect(doc):
    """Flatten the grouped report into (id, status) pairs.

    The reporter nests checks under `groups`, and has used both `checks` and
    `cases` for the inner list across versions. Accept either rather than let a
    key rename silently produce an empty — and therefore passing — run.
    """
    out = []
    for group in doc.get("groups", []) or []:
        for check in (group.get("checks") or group.get("cases") or []):
            status = check.get("status")
            if status is None and "passed" in check:
                status = "passed" if check["passed"] else "failed"
            out.append((check.get("id") or check.get("name") or "<unnamed>", status))
    return out


def main():
    path, label = sys.argv[1], sys.argv[2]

    try:
        with open(path) as fh:
            doc = json.load(fh)
    except Exception:
        print(f"    could not parse protocol output for {label} — see {path}")
        return 1

    checks = collect(doc)

    # Same guard as the OAuth grader, same reason: no checks found is not a pass.
    if not checks:
        print(
            f"    NO SIGNAL — {label}: report contained zero checks. "
            f"Grading nothing; check the reporter shape in {path}."
        )
        return 1

    failed = [c for c, s in checks if s == "failed"]
    skipped = [c for c, s in checks if s == "skipped"]
    other = [(c, s) for c, s in checks if s not in ("passed", "failed", "skipped")]

    if failed or skipped or other:
        print(f"    PROTOCOL — {label}: {len(checks)} checks, "
              f"{len(failed)} failed, {len(skipped)} skipped")
        for c in failed:
            print(f"      failed:  {c}")
        for c in skipped:
            # Named, not counted. A skip usually means auth did not establish,
            # and the specific check tells you where the handshake stopped.
            print(f"      skipped: {c}")
        for c, s in other:
            print(f"      {s}: {c}")
        return 1

    print(f"    all {len(checks)} protocol checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
