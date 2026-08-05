#!/usr/bin/env python3
"""Grade one `mcpjam oauth conformance` run.

The CLI's own exit code is not usable as a verdict: it reports failure unless
the WHOLE flow completes, and ours cannot — the authorization endpoint requires
a Clerk session and nothing headless sits through that. This is the only verdict.

Usage: grade_oauth_conformance.py <results.json> <label>
Exit 0 = reached the consent gate cleanly.
Exit 1 = regression, or no signal.
Exit 2 = combination not applicable (CLI refused it, e.g. CIMD on 2025-03-26).
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from report_io import load_report  # noqa: E402

# Everything from here on needs a human at a Clerk login form.
CONSENT_GATED = {
    "received_authorization_code",
    "token_request",
    "received_tokens",
    "authenticated_mcp_request",
}


def http_status(step):
    return ((step.get("http") or {}).get("response") or {}).get("status")


def main():
    path, label = sys.argv[1], sys.argv[2]

    try:
        doc, _preamble = load_report(path)
    except Exception as exc:
        print(f"    could not parse output for {label}: {exc}")
        return 1

    # The CLI refuses combinations that never existed — CIMD did not exist in
    # 2025-03-26 or 2025-06-18, so those matrix cells are not a server verdict
    # at all. Reported as N/A rather than silently dropped, and distinguished
    # from a real failure by the CLI's own USAGE_ERROR code so that a flag we
    # typo does not quietly become "not applicable" everywhere. The caller
    # separately requires each strategy to grade at least one cell.
    err = doc.get("error") or {}
    if err.get("code") == "USAGE_ERROR":
        print(f"    n/a — {label}: {err.get('message', '').strip()}")
        return 2

    # The step NAME alone is not enough, and getting this wrong once already cost
    # a green run against a server we knew was broken.
    #
    # `received_authorization_code` fails on a HEALTHY server too — the runner
    # cannot sit through a Clerk login. But it failed on the BROKEN server as
    # well, for an entirely different reason, and both surface under the same
    # name. The distinguishing signal is the HTTP status our authorization
    # endpoint returned:
    #
    #   200 -> we accepted the client and served the consent SPA. Healthy; the
    #          runner simply cannot go further without a human. (The CLI follows
    #          the redirect, so the status recorded is the consent page's, not
    #          the 302 that got it there — observed on both strategies
    #          2026-08-05.)
    #   400 -> `render_client_error(conn, "invalid_client")`. THE BUG.
    #
    # So a consent-gated step is excused only when the server did not answer 4xx.
    # Anything else is a regression regardless of which step reported it.
    problems = []
    for step in doc.get("steps", []):
        if step.get("status") != "failed":
            continue
        name = step.get("step")
        status = http_status(step)
        msg = (step.get("error") or {}).get("message", "")
        if name not in CONSENT_GATED:
            problems.append((name, status, msg))
        elif status is not None and status >= 400:
            problems.append((name, status, msg))

    if problems:
        print(f"    REGRESSION — {label}:")
        for name, status, msg in problems:
            print(f"      {name} [HTTP {status}]: {msg[:150]}")
        return 1

    reached = {s.get("step") for s in doc.get("steps", []) if s.get("status") == "passed"}

    # An empty `problems` list is not the same as a healthy run. If the CLI
    # renames `steps`, changes the shape under it, or dies before emitting any,
    # the loop above iterates nothing and this reports a clean pass — the exact
    # vacuous-green this suite exists to prevent, in the suite itself.
    # CLI_VERSION is pinned, so this fires on a conscious bump, not out of
    # nowhere.
    #
    # `authorization_request` is the assertion because it is the last step
    # before the consent wall: reaching it means discovery, metadata, client
    # registration (either path) and PKCE all really ran.
    if "authorization_request" not in reached:
        print(
            f"    NO SIGNAL — {label}: never reached authorization_request "
            f"({len(reached)} steps passed). Suite is not grading the server; "
            f"check the CLI output shape in {path}."
        )
        return 1

    print(f"    reached the consent gate cleanly ({len(reached)} steps passed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
