# Context Doc: Backlog drift from `Refs #N`

_Last verified: 2026-08-08_

## Status

Working (detection recipe verified against the 2026-08-08 sweep — found 4 stale tickets out of 148 open)

## What This Is

A recurring failure mode in this repo's issue tracker: **work ships, the issue stays open, and its body keeps asserting a diagnosis the code has already invalidated.** The next person to pick the ticket up plans against a description that is no longer true.

This is a side effect of a convention that is otherwise correct, so it will keep happening. Sweep for it periodically rather than trying to prevent it.

## Why it happens

`AGENTS.md` and the project conventions require `Refs #N` (not `Closes #N`) for partial work — correct, because `Closes` on a multi-phase tracker kills it after phase one. But nothing ever sweeps the `Refs` back up.

The pathology compounds when the fix documents itself **in the source**:

- **#902** — the version CAS shipped in #907. `crdt_checkpoint.ex:377` is literally commented `# #902 fence`. The code named the issue; nobody told the issue.
- **#648** — accumulated FIVE merged PRs (#1240, #1266, #1270, #1280, #1304) across two weeks. Every one said `Refs`.
- **#1067 / #1017** — both fixed by #1133, whose in-file comment block narrates the exact incident from #1067 in detail.

A second, related shape: **the ticket records a measurement rather than the condition it stood for.**

- **#558** claimed "the Clerk orphan reaper cron silently stopped," evidenced by `gh run list --workflow clerk-orphans.yml` returning nothing after 2026-06-02. What actually happened: #416 **consolidated 6 crons into `cron.yml` on that exact date** and renamed the job `clerk-orphans` → `e2e-orphans`. The reaper never stopped. The query was pointed at a deleted file, and the "last run" and the "silent stop" were the same event.

When the plumbing moves, a measurement-shaped ticket breaks while the condition stays healthy — and the ticket goes on asserting a fire that never existed. #558 sat as a **p1** for two months on that basis.

## Detection recipe

Run this before planning any work off an issue older than a few weeks.

### 1. Cross-reference open issues against commit references

```bash
cd backend  # or the target repo
gh issue list --limit 200 --json number --jq '.[].number' | sort > /tmp/open.txt

git log --since="5 months ago" --pretty=format:"%s %b" main \
  | grep -oiE '(clos(e|es|ed)|fix(e|es|ed)?|resolv(e|es|ed)|refs?) #[0-9]+' \
  | grep -oE '[0-9]+' | sort -u > /tmp/refd.txt

comm -12 <(sort /tmp/open.txt) <(sort /tmp/refd.txt) | sort -n
```

> `comm` needs **lexicographic** sort on both inputs. Sorting numerically (`sort -n`) makes it silently emit garbage with a `file N is not in sorted order` warning that is easy to miss.

Every number this prints is an open issue that merged work already touched. It is a **candidate list, not a verdict** — most will be genuine partial work.

### 2. Verify against the code, never the issue body

This is the step that matters. For each candidate, grep for the thing the issue says is missing:

```bash
# #687 "rate limiter emits NO telemetry"
grep -n "rate_limiter" lib/engram_web/telemetry.ex   # → it does, since PromEx.RateLimiter

# #554 "Hammer Redis connection is still a single conn per node"
grep -rniE 'redis|redix' lib/ config/                # → only historical comments; Redis removed in #684

# #760 "gate the write path when :crdt_enabled is false"
grep -rn "crdt_enabled" lib/ config/                 # → flag no longer exists
```

An issue body is a snapshot of what was true when someone typed it. The code is what is true now.

### 3. Check for a renamed / consolidated producer

For any ticket whose evidence is "this workflow/job/file stopped appearing," confirm the thing still exists under that name before believing it:

```bash
ls .github/workflows/<name>.yml           # gone?
git log --diff-filter=D -- .github/workflows/<name>.yml   # who deleted it, and when
```

Compare that deletion date against the ticket's "last seen" date. If they match, the ticket is measuring a rename.

## Failed Approaches / Dead Ends

- **Trusting the `Refs`/`Closes` split as a signal of doneness.** It only records intent at commit time. A `Refs` on the PR that happened to finish the work looks identical to a `Refs` on phase 1 of 5.
- **Reading the issue's own comments to decide if it is done.** Comments track the *investigation*, not the fix. #902 had a thorough comment thread and no note that #907 had shipped the CAS.
- **Assuming a p1 label reflects current severity.** #558 was p1 for two months on a false premise. Age plus priority is not evidence.
- **Closing straight off the cross-reference.** Of 13 candidates in the 2026-08-08 sweep, only some were done; the rest were genuine partial work. Step 2 is not optional.

## Gotchas

- **The fix often names the issue in a code comment while leaving the issue open.** Grepping `lib/` for `#<number>` is a fast, high-yield check that most people never run.
- **Two issues describing one race are usually both fixed together.** #1067 (prevent the race) and #1017 (fail fast if it happens) both closed on #1133's single wait step.
- **A stale ticket can be worse than no ticket.** It occupies priority, and it aims the next session at a diagnosis that is already wrong. Both effects are invisible until someone plans against it.
- Squash-merge means `git branch --merged` will not show these branches as merged either — see `../engram-workspace/docs/context/worktree-hygiene.md` for the same class of lie.

## References

- 2026-08-08 sweep: closed #648, #687, #689, #534, #799, #713, #554, #760, #685, #558, #1067, #1017, #902
- `AGENTS.md` — the `Refs` vs `Closes` convention and the `phase/*` migration labels
- `../engram-workspace/docs/context/worktree-hygiene.md` — squash-merge makes `--merged` lie
