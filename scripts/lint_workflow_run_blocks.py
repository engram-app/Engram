#!/usr/bin/env python3
r"""Syntax-check every `run:` script in the given workflow files.

Usage:
    lint_workflow_run_blocks.py .github/workflows/*.yml

YAML linting proves a workflow file PARSES. It says nothing about whether
the shell inside `run:` is valid — a `run:` block is just an opaque string
to the YAML parser. So a workflow can be perfectly well-formed YAML and
still fail at execution on every invocation.

The specific trap this was written for: an edit that inserts a `#` comment
into the middle of a backslash-continued command.

    curl -sS \\
      # explanatory comment            <-- kills the command
      --data "$payload" \\
      "$URL"

That is valid YAML and reads fine in review. It is also NOT a syntax error,
which is the nasty part: the `#` comment swallows the rest of the logical
line, so `--data "$payload"` becomes a separate command and bash reports
`--data: command not found` at RUNTIME. `bash -n` sails straight past it.
Since the notify steps it appeared in only run on release/failure paths, it
would not have surfaced until the moment it was needed.

So there are two checks here, and the structural one is the important one:

  1. comment-after-continuation — a line starting with `#` whose preceding
     line ends in `\`. Detected structurally, because bash cannot.
  2. `bash -n` — catches the things that ARE syntax errors (unterminated
     quotes, unclosed here-docs, dangling `fi`).
"""

import re
import subprocess
import sys

import yaml

# `${{ ... }}` is substituted by Actions before the shell ever sees it, so
# it must be neutralised before parsing. Match the whole span: a naive
# `}}` -> `}` replace also eats the tail of legitimate shell forms like
# ${VAR:0:${#OTHER}} and invents syntax errors that aren't there.
GH_EXPR = re.compile(r"\$\{\{.*?\}\}", re.S)

# Only bash/sh blocks. `shell: python` etc. are not our business.
SHELL_OK = {"bash", "sh", None}


def comment_after_continuation(script: str) -> list[tuple[int, str]]:
    """Lines starting a comment while the previous line is still continuing.

    bash treats the comment as consuming the remainder of the logical line,
    silently orphaning whatever came next. Not a syntax error, so this has
    to be found structurally.
    """
    bad = []
    prev_continues = False
    for lineno, raw in enumerate(script.splitlines(), 1):
        stripped = raw.strip()
        if prev_continues and stripped.startswith("#"):
            bad.append((lineno, stripped))
        # Blank lines can't continue anything; ignore them for state.
        if stripped:
            prev_continues = stripped.endswith("\\")
    return bad


def main(paths: list[str]) -> int:
    failures = 0
    checked = 0

    for path in paths:
        with open(path) as fh:
            doc = yaml.safe_load(fh)
        if not doc:
            continue

        for job_name, job in (doc.get("jobs") or {}).items():
            for idx, step in enumerate(job.get("steps") or []):
                script = step.get("run")
                if not script or step.get("shell") not in SHELL_OK:
                    continue

                checked += 1
                name = step.get("name", "(unnamed)")
                probe = GH_EXPR.sub("GHEXPR", script)

                for lineno, text in comment_after_continuation(probe):
                    failures += 1
                    print(f"::error file={path}::{job_name} / step[{idx}] {name}")
                    print(
                        f"    line {lineno}: comment follows a line-continuation, "
                        f"orphaning the rest of the command: {text}"
                    )

                proc = subprocess.run(
                    ["bash", "-n"], input=probe, text=True, capture_output=True
                )
                if proc.returncode != 0:
                    failures += 1
                    print(f"::error file={path}::{job_name} / step[{idx}] {name}")
                    for line in proc.stderr.strip().splitlines():
                        print(f"    {line}")

    print(f"Checked {checked} run-blocks in {len(paths)} workflow(s); {failures} bad.")
    return 1 if failures else 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: lint_workflow_run_blocks.py <workflow.yml>...", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1:]))
