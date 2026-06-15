# Security Policy

We take security seriously. If you've found a vulnerability in Engram, please
report it privately so we can fix it before public disclosure.

## Reporting a vulnerability

Email **security@engram.page** with:

- A description of the issue and its impact
- Steps to reproduce (proof-of-concept if possible)
- The version, commit SHA, or URL where you observed it
- Whether you've shared this with anyone else

We aim to acknowledge reports within **48 hours** and to provide a status
update or fix within **14 days** for confirmed issues. Critical-severity
issues are handled out-of-band.

If you'd like to encrypt, ask in your first email and we'll arrange a key.

## In scope

- **SaaS production** — `app.engram.page` (web app + REST API + WebSocket +
  MCP server)
- **Backend** — this repository (`engram-app/engram`) when running a tagged
  release
- **Plugin** — `engram-app/Engram-obsidian` (Engram Vault Sync) when running
  a tagged release. See its
  [SECURITY.md](https://github.com/engram-app/Engram-obsidian/blob/main/SECURITY.md)
  for plugin-specific scope.

## Out of scope

- Older releases superseded by a newer tagged version
- Self-host deployments running on a private LAN (e.g., `engram.ax`,
  user-operated docker-compose) — security depends on the operator's
  network and infra
- Third-party services we integrate with — please report directly upstream:
  - Clerk (auth) — `security@clerk.com`
  - Paddle (billing) — Paddle's responsible disclosure program
  - AWS, Qdrant Cloud, Voyage AI — their respective programs
- Findings that require physical access, a compromised endpoint, or social
  engineering of an Engram employee
- Denial-of-service from sustained load against shared infrastructure (a
  heads-up is welcome, but it's not a vulnerability report)
- Missing security headers, cookie attributes, or framework defaults without
  a demonstrated impact
- Vulnerabilities in unmaintained dependencies without a working exploit
  path

## Safe harbor

We will not pursue legal action against good-faith research that:

- Avoids privacy violations, data destruction, and service degradation
- Stops at the minimum proof needed to demonstrate the issue
- Does not access, modify, or exfiltrate other users' data beyond what's
  strictly necessary to demonstrate the issue
- Reports the issue to us privately before any public disclosure
- Gives us reasonable time to fix before disclosing

If in doubt about whether your testing falls under safe harbor, email us
first and ask.

## Bounty

No paid bounty at launch. We will publicly credit researchers (with their
permission) in release notes and in this file once we've shipped a fix.

## Recent advisories

None yet.
