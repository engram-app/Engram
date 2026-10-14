# Context: Telling users about legal changes

_Last verified: 2026-10-14_

Nobody sends anything by hand. Publishing a Terms of Service or Privacy Policy
version is the whole procedure; the app announces it everywhere.

## Publishing a version

1. Vendor the new text and manifest hash (marketing PR first, then the
   backend re-vendor; the cross-repo legal check pairs them).
2. Add its entry to `@version_meta` in `lib/engram/legal/seeder.ex`:
   - `effective_date` in the future. That date is what triggers every notice.
     `nil` means effective at once and silent: wording fixes only.
   - `material: true` if users must accept it to keep using Engram. It then
     needs an `effective_date` at least 30 days after its version date (ToS
     §13). `Seeder.notice_violations/0` fails CI otherwise.
   - `changelog`: one plain sentence. It is the "what changed" line in the
     email, the web banner, the plugin Notice and MCP.
3. Deploy. Nothing else.

## What users get

| Channel | When | Where |
|---|---|---|
| Email | Within the hour after deploy, once per user | `Workers.LegalNoticeDispatch` (hourly cron, `:18`) fans out `Workers.LegalNoticeEmail` |
| Reminder email | 7 days before a MATERIAL change, to users who have not accepted | same dispatch |
| Web banner | Until accepted or the effective date | `frontend/src/legal/legal-notice-banner.tsx` |
| Agreement page | "What changed" list | `frontend/src/onboarding/agreement-page.tsx` |
| Obsidian plugin | Sticky Notice at launch and daily; notice-only once per version | plugin `src/legal-notices.ts` |
| MCP | One line on a tool result, once a day per user | `McpController.legal_note/2` |

All of them read one list: `Engram.Onboarding.legal_notices/1` (on
`/api/onboarding/status` and `/api/bootstrap` as `legal_notices`). A notice
exists while the version is unaccepted and its effective date is in the
future.

On the effective date a material change moves the floor
(`VersionCache.required_floor/2` is keyed by date, so no deploy or cache reset
is needed) and the onboarding gate asks for acceptance. A notice-only change
simply applies.

## Gotchas

- **Dismissing a notice-only banner records acceptance** of the current
  versions (`useAcceptCurrentAgreements`). That is what keeps it dismissed on
  every device. A material banner has no dismiss.
- **Sends are claimed, not checked.** `notified_at` / `reminded_at` on
  `terms_versions` are set by a conditional UPDATE in the same transaction as
  the Oban inserts, so two nodes or a retry never double-send and a crash never
  loses one. To resend, null the column.
- **The latest accepted version is the highest version, not the newest row.**
  Two accepts in one second tie on `accepted_at` (second precision).
- **`Engram.Cache` cannot hold a struct in its key.** Its match-spec store
  fails and the `rescue ArgumentError` swallows it, so the cache silently never
  hits. The floor key uses the ISO date string for that reason.
- Legal email is transactional: analytics opt-out does not apply, but
  bounced/complained addresses (`Email.Suppression`) are skipped.
- Self-host has no notices (`billing_enabled` false, nothing seeded).
