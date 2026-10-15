# Context: Telling users about legal changes

_Last verified: 2026-10-14_

Nobody sends anything by hand. Publishing a Terms of Service or Privacy Policy
version is the whole procedure; the app announces it everywhere.

## Publishing a version

1. Vendor the new text and manifest hash (marketing PR first, then the
   backend re-vendor; the cross-repo legal check pairs them).
2. Add its entry to `@version_meta` in `lib/engram/legal/seeder.ex`:
   - `effective_date` in the future. That date is what triggers every notice.
     `nil` means effective at once and silent. Only for a non-material
     change that adds no new processing (wording, new explanatory sections,
     a dropped sub-processor). Anything users must be told about needs a
     date. A silent version's changelog is never shown, so `email-keys.ts`
     does not send it for translation.
   - `material: true` if users must accept it to keep using Engram. It then
     needs an `effective_date` at least 30 days after its version date (ToS
     §13). `Seeder.notice_violations/0` fails CI otherwise.
   - `changelog`: one plain sentence. It is the "what changed" line in the
     email, the web banner, the plugin Notice and MCP.
3. Deploy. Nothing else.

## What users get

| Channel | When | Where |
|---|---|---|
| Email | Within the hour after deploy, once per user (again if the date or materiality changes) | `Workers.LegalNoticeDispatch` (hourly cron, `:18`) fans out `Workers.LegalNoticeEmail` |
| Reminder email | 7 days before a MATERIAL change, to users who have not accepted | same dispatch |
| Web banner | Until accepted or the effective date | `frontend/src/legal/legal-notice-banner.tsx` |
| Agreement page | "What changed" list | `frontend/src/onboarding/agreement-page.tsx` |
| Obsidian plugin | Sticky Notice at launch and daily; notice-only once per version | plugin `src/legal-notices.ts` |
| MCP | One line on a tool result, once a day per user | `McpController.legal_note/2` |

All of them read one list: `Engram.Onboarding.legal_notices/1` (on
`/api/onboarding/status` and `/api/bootstrap` as `legal_notices`), at most one
per document. A version counts once it is announced (has an effective date)
and unaccepted. A notice-only one drops on its date; a material one stays
listed after it, so the agreement page can show what changed. A later silent
version never hides an announced change behind it.

Accepting (`POST /api/onboarding/accept-terms`) takes any version whose hash
matches its `terms_versions` row and that is at or above the floor, not only
the latest: a browser on a bundle built before a publish accepts the newest
text it can render (`frontend/src/legal/use-accept-current.ts`), and the banner
records the version it showed. `Legal.current_version/1` is capped at the
newest version in the running build's manifest, so a rollback stops offering a
version that build cannot render; the row stays because acceptances reference
it.

On the effective date a material change moves the floor
(`VersionCache.required_floor/2` recomputes when the date changes, so no deploy
or cache reset is needed) and the onboarding gate asks for acceptance. This
holds for BOTH documents. A privacy version with no effective date (the
baseline) never gates, because accounts from before privacy versions were
tracked hold an older or no privacy acceptance.

## Gotchas

- **Dismissing a notice-only banner records acceptance** of the current
  versions (`useAcceptCurrentAgreements`). That is what keeps it dismissed on
  every device. A material banner has no dismiss.
- **Sends are claimed, not checked.** `notified_at` / `reminded_at` on
  `terms_versions` are set by a conditional UPDATE in the same transaction as
  the Oban inserts, so two nodes or a retry never double-send and a crash never
  loses one. That claim is the only dedupe: `Oban.insert_all` ignores `unique`
  on Oban OSS. To resend, null the column.
- **Changing an announced version's `effective_date` or `material` emails
  everyone again.** The seeder's upsert clears both stamps when either
  changes, because the first email named the wrong date or said no action was
  needed. A date fix after announcing is a mass email; get the date right
  before deploying.
- **The latest accepted version is the highest version, not the newest row.**
  Two accepts in one second tie on `accepted_at` (second precision).
- **`Engram.Cache` cannot hold a struct in its key.** Its match-spec store
  fails and the `rescue ArgumentError` swallows it, so the cache silently never
  hits. Structs in the VALUE are fine. The floor entry stores its date as an
  ISO string for that reason.
- **The email is in the user's language** (`users.locale`, see
  `webapp-i18n.md` "Email"), including the changelog line. A new changelog
  goes out in English if it ships before the nightly bot translates it, so
  run `bun run i18n:translate` in the publishing PR.
- Legal email is transactional: analytics opt-out does not apply, but
  bounced/complained addresses (`Email.Suppression`) are skipped.
- Self-host has no notices (`billing_enabled` false, nothing seeded).
