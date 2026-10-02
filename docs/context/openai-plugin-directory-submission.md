# Context Doc: OpenAI (ChatGPT) Plugin Directory Submission

_Last verified: 2026-10-01_

## Status
Working. Submitted for review; domain verification and reviewer login both pass.

## What This Is
How Engram is packaged and submitted to the ChatGPT plugin directory, plus the traps hit on the way: duplicate-plugin MCP URL lock, domain verification through the MCP host, and a reviewer login that must not ask for any code.

## Environment
- Package source: `openai-plugin/` in this repo (`plugin.json` in the Agent Plugins format, `mcp.json` pointing at `https://mcp.engram.page`, `assets/`).
- Submission spec: https://developers.openai.com/plugins/deploy/submission
- Portal: OpenAI platform dashboard, plugin directory section.

## Key Commands / Patterns

### Build the ZIP
The submission is a ZIP upload, not a form.

```bash
cd openai-plugin && zip -r ../engram-openai-plugin.zip .
```

### Always "Upload plugin to make changes"
Upload new versions through "Upload plugin to make changes" on the EXISTING plugin. "Upload new" creates a second plugin, and that one fails with:

> This MCP URL is already used by another app in your organization

Only one plugin per org may claim an MCP URL. The fix was deleting the older draft. Changing the MCP URL of a plugin later requires OpenAI support.

### Domain verification
OpenAI fetches `https://mcp.engram.page/.well-known/openai-apps-challenge` and expects the portal token as the bare `text/plain` body.

- Served by `WellKnownController.openai_apps_challenge/2`, reading env `OPENAI_APPS_CHALLENGE` (PR #1811).
- The route has NO router pipeline on purpose: `:api` returns 406 for a `text/plain` Accept, and `:public_cacheable` would pin a stale token at the Cloudflare edge.
- `HostRewrite` had to allowlist the path on the MCP host, otherwise it 404s.
- Prod value lives in engram-infra `main/envs/prod/ecs.tf` as a plain env var (public by design; engram-infra PR #1297).
- The token only rotates if the plugin is deleted and recreated.

Verify by curling until N consecutive hits return the token. During an ECS rollout old and new tasks alternate, so you will see 404 and token interleaved until the rollout finishes:

```bash
for i in $(seq 1 10); do curl -s --max-time 5 https://mcp.engram.page/.well-known/openai-apps-challenge; echo; done
```

### Review package requirements
- Exactly 5 positive and 3 negative test cases. The dashboard imports them read-only from `plugin.json` `review.test_cases`; to change them, edit the ZIP and re-upload.
- `demo_recording_url` (current: https://youtu.be/-25120oVXF0).
- Four HTTPS listing URLs: website, support, privacy, terms. `engram.page/support` was added in engram-marketing PR #208.
- Reviewer credentials go in the dashboard "Review details" form, never in the ZIP (`test_credentials` in the ZIP is rejected).
- Test cases must match the reviewer account's data. The reviewer account holds a copy of the Northwind Studio sample vault. Delete any `90 Work Log` folder from that copy: real work logs had leaked into Northwind.

### Listing copy
Source: engram-workspace `docs/context/messaging.md`, ChatGPT variant. OpenAI flags a name or description that "references another AI assistant, model, or platform", and bars comparisons with other products and advertised pricing.

- Name: `Engram AI Memory`
- Subtitle: `AI memory you edit in Obsidian`

### Testing the unpublished plugin in ChatGPT (demo video)
The platform "Connect" button only connects OpenAI's scanner, not your ChatGPT account. To use it yourself: enable ChatGPT Developer mode, add `https://mcp.engram.page` as a custom app, then OAuth in as the reviewer account.

### After publication
OpenAI rescans the MCP server daily. Tool changes need no new ZIP. Metadata or skills changes need a new ZIP and another review. Skills follow-up: issue #1816.

## Auth: reviewer login without codes
OpenAI requires reviewer creds that "work immediately without MFA approval, email or SMS codes, magic links".

Clerk Device Trust forces an email code on password sign-in from a new device for users without MFA, and the Dashboard toggle is instance-wide. The way out is a per-user Backend API flag, `bypass_client_trust`:

- Present in clerk/openapi-specs since 2025-12-11 and in Clerk's Python/Ruby/PHP/C# SDKs. NOT in the Node SDK, NOT in the Dashboard, not in the guides.
- Set with a raw PATCH using the prod secret key:

```bash
cd ../engram-infra
CLERK_SK=$(./bin/sops-engram prod --decrypt --extract '["clerk_sk"]' secrets/prod.enc.yaml)
curl -s -X PATCH "https://api.clerk.com/v1/users/<user_id>" \
  -H "Authorization: Bearer $CLERK_SK" -H "Content-Type: application/json" \
  -d '{"bypass_client_trust": true}' -o /dev/null -w '%{http_code}\n'
unset CLERK_SK
```

Never decrypt the key to stdout.

- Set on `reviewer@engram.page` (`user_3K21Zi3z7c2H1FNqROZQR1YMy51`). Verified live: a fresh incognito sign-in had no code prompt, while normal users still get the code.
- Risk: undocumented, Clerk could remove it. Re-verify with a fresh incognito sign-in before every resubmission.

## Failed Approaches / Dead Ends
- "Upload new" for a revised package: creates a duplicate plugin that cannot claim the MCP URL (see above).
- Clerk test mode (`+clerk_test` email with code `424242`): rejected, because 424242 is still an email code under OpenAI's rule.
- Turning off Device Trust in the Clerk Dashboard: instance-wide, so it weakens every real user. Not done.
- Mounting the challenge route under `:api` (406 on `text/plain`) or `:public_cacheable` (stale token cached at the edge).
- Using the platform "Connect" button to test in ChatGPT: it only connects OpenAI's scanner.

## Gotchas
- Challenge path 404 on the MCP host until `HostRewrite` allowlists it.
- Mixed 404/token responses mean a rollout is in progress, not a bug.
- Test cases are read-only in the dashboard; only the ZIP changes them.
- Reviewer vault content must match the test cases, and must not contain real data.

## References
- `openai-plugin/` (package source)
- `WellKnownController.openai_apps_challenge/2`, PR #1811
- engram-infra `main/envs/prod/ecs.tf`, PR #1297
- engram-marketing PR #208 (support page)
- engram-workspace `docs/context/messaging.md` (listing copy)
- engram-workspace `reports/Clerk reviewer login without codes.md` (full Clerk research, untracked)
- Issue #1816 (skills follow-up)
