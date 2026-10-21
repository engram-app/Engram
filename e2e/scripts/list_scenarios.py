#!/usr/bin/env python3
"""List canary scenarios from Playwright and pytest discovery output.

Playwright: `playwright test --list --reporter=json` (tag `@canary`, annotations
`cadence` and `targets`). Pytest: JSON written by the conftest hook when
SCENARIO_COLLECT_OUT is set (`[{nodeid, cadence, targets}]`, marker `canary`).
Prints a JSON array; exits 1 naming any scenario with a missing or unknown
cadence/target.
"""

from __future__ import annotations

import argparse
import json
import sys

CADENCES = {"10m", "hourly", "2h", "daily"}
TARGETS = {"ci", "staging", "staging-limits", "prod"}


def _playwright_specs(suite):
    yield from suite.get("specs", [])
    for child in suite.get("suites", []):
        yield from _playwright_specs(child)


def _playwright(doc):
    for top in doc.get("suites", []):
        for spec in _playwright_specs(top):
            tags = list(spec.get("tags", []))
            if "@canary" not in tags:
                continue
            ann = {
                a["type"]: a.get("description", "")
                for t in spec.get("tests", [])
                for a in t.get("annotations", [])
            }
            targets = [t for t in ann.get("targets", "").split(",") if t]
            yield (
                spec["title"],
                "playwright",
                spec.get("file", ""),
                ann.get("cadence"),
                targets,
                tags,
            )


def _pytest(entries):
    for e in entries:
        yield (
            e["nodeid"],
            "pytest",
            e["nodeid"].split("::")[0],
            e.get("cadence"),
            list(e.get("targets") or []),
            ["canary"],
        )


def _problem(cadence, targets):
    if cadence not in CADENCES:
        return f"cadence {cadence!r} not in {sorted(CADENCES)}"
    if not targets:
        return "targets missing"
    bad = [t for t in targets if t not in TARGETS]
    return f"unknown targets {bad} (allowed {sorted(TARGETS)})" if bad else None


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--playwright-json", required=True)
    ap.add_argument("--pytest-collect", required=True)
    args = ap.parse_args(argv)
    with open(args.playwright_json) as f:
        pw = json.load(f)
    with open(args.pytest_collect) as f:
        py = json.load(f)

    out, errors = [], []
    for name, runner, file, cadence, targets, tags in [*_playwright(pw), *_pytest(py)]:
        if (why := _problem(cadence, targets)) is not None:
            errors.append(f"scenario {name!r} ({file}): {why}")
            continue
        out.append(
            {
                "name": name,
                "runner": runner,
                "file": file,
                "cadence": cadence,
                "targets": targets,
                "tags": tags,
            }
        )
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(json.dumps(out, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
