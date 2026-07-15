<div align="center">

# Engram

![Engram — your notes are your AI's memory, synced everywhere and read by your AI](assets/vault-banner.gif)

**Your notes are your AI's memory.**

MCP-native · semantic + keyword search · real-time sync · self-hostable · source-available · Elixir/Phoenix

[![MCP](https://img.shields.io/badge/MCP-native-8A2BE2)](https://modelcontextprotocol.io)
[![Last commit](https://img.shields.io/github/last-commit/engram-app/Engram)](https://github.com/engram-app/Engram/commits/main)
[![Stars](https://img.shields.io/github/stars/engram-app/Engram?style=flat)](https://github.com/engram-app/Engram/stargazers)
[![License](https://img.shields.io/badge/license-PolyForm_SB_1.0-blue)](LICENSE)
[![Sponsor](https://img.shields.io/github/sponsors/engram-app?label=Sponsor&logo=GitHub&color=ea4aaa)](https://github.com/sponsors/engram-app)
[![Ko-fi](https://img.shields.io/badge/Ko--fi-Buy_a_coffee-FF5E5B?logo=ko-fi&logoColor=white)](https://ko-fi.com/engrams_sync)

[Quickstart](#self-host-docker-compose) · [Self-host](https://engram.page/docs/self-host/) · [MCP](https://engram.page/docs/mcp/) · [API](https://engram.page/docs/api/) · [Architecture](https://engram.page/docs/self-host/architecture/) · [Plugin](https://github.com/engram-app/Engram-obsidian) · [Discord](https://discord.gg/NKWcU2mm7N)

</div>

Your notes stay plain markdown that you and your AI assistants both read and
write. Pairs with the
[Engram Obsidian Sync](https://github.com/engram-app/Engram-obsidian) plugin to
sync your whole vault.

## Self-Host (Docker Compose)

**Don't want to run the commands yourself?** Open the
[Quickstart docs](https://engram.page/docs/self-host/quickstart/), select
the whole page, and paste it into your AI assistant — it's written
top-to-bottom as imperatives the AI can execute in order.

Otherwise:

```bash
git clone https://github.com/engram-app/Engram.git
cd Engram
cp .env.example .env       # then fill in the three secrets at the top
docker compose up -d
```

App at <http://localhost:4000>. Migrations run on boot. Only port 4000 is
host-exposed; everything else stays on the private Docker network.

**Large vaults?** Enable MinIO for S3-style attachments:
`docker compose --profile s3 up -d` — see
[storage docs](https://engram.page/docs/self-host/environment-variables/#storage).

**Better embeddings?** Switch to Voyage AI in `.env` — see
[embeddings docs](https://engram.page/docs/self-host/environment-variables/#embeddings).

### Full self-host documentation

| Topic | Link |
|---|---|
| Quickstart           | <https://engram.page/docs/self-host/quickstart/> |
| Environment vars     | <https://engram.page/docs/self-host/environment-variables/> |
| Encryption & keys    | <https://engram.page/docs/self-host/encryption/> |
| Backup & restore     | <https://engram.page/docs/self-host/backup-restore/> |
| Upgrades             | <https://engram.page/docs/self-host/upgrade/> |
| Troubleshooting      | <https://engram.page/docs/self-host/troubleshooting/> |
| Architecture         | <https://engram.page/docs/self-host/architecture/> |
| MCP setup            | <https://engram.page/docs/mcp/> |
| HTTP API             | <https://engram.page/docs/api/> |

## Community

Questions, ideas, or bug reports? Join us on [Discord](https://discord.gg/NKWcU2mm7N).

## Contributing

Local dev setup, tests, and PR rules: see [CONTRIBUTING.md](./CONTRIBUTING.md).

## License

Dual-licensed:
- **[PolyForm Small Business 1.0.0](./LICENSE)** — free for organizations
  under $1M USD prior-year revenue and < 100 employees + contractors.
- **Commercial License** — required for larger orgs. See
  [LICENSE-COMMERCIAL.md](./LICENSE-COMMERCIAL.md) or email
  `support@engram.page`.

External contributions sign the [Engram CLA](./.github/CLA.md). See
[CONTRIBUTING.md](./CONTRIBUTING.md).

## Security

See [SECURITY.md](./SECURITY.md) for vulnerability disclosure. Self-host LAN
deployments are out of scope of our published SLA — security depends on the
operator's network and infra.

Copyright (c) 2026 Rasbandit Software Solutions LLC d/b/a Engram.
