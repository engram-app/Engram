"""Load an MCPJam JSON report out of output that also carries prose.

The CLI prints advisory lines to STDOUT, ahead of the document:

    Client.listResources() called but server does not advertise resources
    capability - returning empty list
    {"schemaVersion":1,"kind":"protocol-conformance",...}

so `json.load` on the raw capture fails and the run reports NO SIGNAL — a
harness fault dressed up as a server verdict. Redirecting stderr elsewhere does
not help; these go to stdout.

The preamble is returned rather than dropped: it explains several of the
failures underneath it (an advisory about an unadvertised capability is exactly
the context you want when the matching check fails), so it belongs in the log.
"""

from __future__ import annotations

import json


def load_report(path: str) -> tuple[dict, str]:
    """Return (document, preamble). Raises ValueError if no document is present."""
    with open(path, errors="replace") as fh:
        raw = fh.read()

    try:
        return json.loads(raw), ""
    except json.JSONDecodeError:
        pass

    start = raw.find("{")
    if start == -1:
        raise ValueError(f"no JSON document found in {path}")

    try:
        return json.loads(raw[start:]), raw[:start].strip()
    except json.JSONDecodeError as exc:
        # Deliberately not a "scan for the last {" retry: at that point we are
        # guessing at the shape of a file we do not understand, and guessing is
        # how a grader ends up certifying something it never read.
        raise ValueError(f"{path} has a leading preamble but no parseable document: {exc}") from exc
