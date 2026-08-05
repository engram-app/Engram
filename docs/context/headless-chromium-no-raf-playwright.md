# Headless Chromium produces zero requestAnimationFrame frames on this box

_Last verified: 2026-08-05_

**Symptom:** Every Playwright click hangs on the actionability "stable" check when running `bunx playwright test` headlessly on this machine (frontend/e2e specs). Existing specs fail identically — it is not test-specific.

## Root cause

Headless Chromium on this box produces zero requestAnimationFrame frames — verified even on `about:blank`, across Chromium builds and GPU flags. Playwright's stability check waits for two consecutive rAF frames to confirm the DOM is ready before executing a click, so it never completes.

## Workaround

Run headed under xvfb:

```bash
cd backend/frontend
xvfb-run -a bunx playwright test --headed
```

Nothing in committed test code depends on this — it is purely a local-run incantation.

## Not affected

CI runner VMs run these specs headless without issue. This is local-box-specific, likely a hypervisor or X11 forwarding issue.

## Unrelated pre-existing issue

Global setup logs a "DB cleanup failed — FK constraints" warning when run against a reused dev DB; this is harmless and orthogonal.
