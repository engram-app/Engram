# Engram

Your vault remembers everything.

AI-powered personal knowledge base that makes your Obsidian vault queryable by any AI assistant via [MCP](https://modelcontextprotocol.io). Built with Elixir/Phoenix. Notes are stored in PostgreSQL, embedded into vectors via Voyage AI, and searched with semantic similarity through Qdrant.

Pairs with the [Engram Obsidian Sync](https://github.com/Rasbandit/Engram-obsidian-sync) plugin for real-time bidirectional sync between Obsidian and the server via Phoenix Channels (WebSocket).

## How It Works

```
                         +-----------------+
                         |    Obsidian     |
                         | (plugin: sync)  |
                         +--------+--------+
                                  |
                    REST API (notes, attachments)
                    WebSocket (Phoenix Channels)
                                  |
                         +--------v--------+
                         |     Engram      |
                         | (Elixir/Phoenix)|
                         +--+---------+--+-+
                            |         |  |
                  +---------+    +----+  +--------+
                  |              |                 |
          +-------v------+ +----v-----+   +-------v-------+
          |  PostgreSQL  | |  Qdrant  |   |   Voyage AI   |
          |  (+ Oban)    | | (vectors)|   |  (embeddings) |
          | notes, auth  | +----------+   +---------------+
          | RLS isolation|
          +--------------+
```

### Data Flow

**Indexing** — when a note arrives:

```
POST /notes (or Channel push_note)
    → store in PostgreSQL (immediate)
    → broadcast to connected devices via PubSub
    → queue Oban embedding job (5s debounce, dedup)
        → parse markdown (Earmark AST, heading-aware chunking)
        → contextualize (prepend folder/heading path)
        → embed via Voyage AI (voyage-4-large, 1024d)
        → upsert into Qdrant
```

**Search** — semantic similarity:

```
query → Voyage AI embed → Qdrant similarity search → top N results
```

### MCP Integration

Any AI assistant that speaks MCP can query your vault:

| Tool | Description |
|------|-------------|
| `search_notes(query, limit, tags)` | Semantic search across your vault |
| `get_note(source_path)` | Fetch full note content |
| `list_tags()` | All tags with document counts |
| `list_folders()` | Folder tree with note counts |
| `write_note(path, content)` | Update or create a note |
| `create_note(title, content, suggested_folder)` | Auto-places in the best folder |
| `suggest_folder(title, content)` | Suggests folder placement based on similar notes |

## Architecture

- **Elixir/Phoenix OTP app** — search, indexing, MCP, sync, and auth all in one supervised application
- **Multi-tenant with RLS** — PostgreSQL Row-Level Security enforces tenant isolation at the database level
- **Phoenix Channels** — bidirectional real-time sync over WebSocket with Presence for device tracking
- **Async indexing via Oban** — embedding jobs are durable, deduplicated, and retried automatically
- **Behaviour-based adapters** — swap embedding backends (Voyage AI / Ollama) without touching search logic
- **No Redis required** — PubSub via Erlang distribution, caching via ETS

## Quick Start

### Prerequisites

- Elixir 1.17+ and Erlang/OTP 27+
- PostgreSQL 16+
- [Qdrant](https://qdrant.tech) running locally or Qdrant Cloud

### 1. Setup

```bash
mix deps.get
mix ecto.setup            # Create DB + run migrations + seeds
bash scripts/install-hooks.sh  # One-time: enables pre-push version-bump check
```

### 2. Configure

```bash
cp .env.example .env
```

Edit `.env` — key variables:

```bash
DATABASE_URL=postgresql://engram:engram@localhost:5432/engram
EMBED_BACKEND=ollama              # or "voyage" for SaaS
EMBED_MODEL=nomic-embed-text      # or "voyage-4-large"
EMBED_DIMS=768                    # or 1024 for Voyage
QDRANT_URL=http://localhost:6333
JWT_SECRET=some-random-string-at-least-32-chars
```

See `docs/context/environment-variables.md` for the full list.

### 3. Start

```bash
mix phx.server    # http://localhost:4000
```

Or with Docker:

```bash
docker compose -f docker-compose.elixir.yml up --build
```

### 4. Register & Create API Key

```bash
# Register
curl -X POST http://localhost:4000/register \
  -H "Content-Type: application/json" \
  -d '{"email": "you@example.com", "password": "your-password"}'

# Login
TOKEN=$(curl -s -X POST http://localhost:4000/login \
  -H "Content-Type: application/json" \
  -d '{"email": "you@example.com", "password": "your-password"}' \
  | jq -r '.token')

# Create API key
curl -X POST http://localhost:4000/api-keys \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "my-key"}'
```

Save the returned API key — it starts with `engram_` and is only shown once.

### 5. Push a Note

```bash
curl -X POST http://localhost:4000/notes \
  -H "Authorization: Bearer engram_your_key_here" \
  -H "Content-Type: application/json" \
  -d '{
    "path": "Notes/Hello World.md",
    "content": "# Hello World\n\nThis is my first note.",
    "mtime": 1709234567.0
  }'
```

### 6. Search

```bash
curl -X POST http://localhost:4000/search \
  -H "Authorization: Bearer engram_your_key_here" \
  -H "Content-Type: application/json" \
  -d '{"query": "hello", "limit": 5}'
```

### 7. Connect the Obsidian Plugin

Install [Engram Obsidian Sync](https://github.com/Rasbandit/Engram-obsidian-sync) via BRAT, then configure:

- **Server URL**: `http://your-server:4000`
- **API Key**: your `engram_` key

The plugin handles full vault sync, live WebSocket updates, offline queueing, and conflict resolution.

## MCP Configuration

### Claude Code

```json
{
  "mcpServers": {
    "engram": {
      "type": "sse",
      "url": "http://your-server:4000/mcp",
      "headers": {
        "Authorization": "Bearer engram_your_key_here"
      }
    }
  }
}
```

### Claude Desktop

```json
{
  "mcpServers": {
    "engram": {
      "url": "http://your-server:4000/mcp",
      "transport": "sse",
      "headers": {
        "Authorization": "Bearer engram_your_key_here"
      }
    }
  }
}
```

## API Reference

### Notes

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/notes` | Upsert a note (creates or updates, triggers async indexing) |
| `GET` | `/notes/{path}` | Get full note by path |
| `DELETE` | `/notes/{path}` | Soft-delete a note |
| `GET` | `/notes/changes?since=<timestamp>` | Notes changed since timestamp (for sync) |

### Search

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/search` | Semantic search with optional tag/folder filtering |
| `GET` | `/tags` | All tags with document counts |
| `GET` | `/folders` | Folder tree with note counts |

### Attachments

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/attachments` | Upsert binary file (base64-encoded) |
| `GET` | `/attachments/{path}` | Get attachment |
| `DELETE` | `/attachments/{path}` | Soft-delete attachment |
| `GET` | `/attachments/changes?since=<timestamp>` | Attachment changes (for sync) |
| `GET` | `/user/storage` | Storage usage stats |

### Auth

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/register` | Register a new user |
| `POST` | `/login` | Login, returns JWT |
| `POST` | `/api-keys` | Create an API key (JWT auth) |
| `DELETE` | `/api-keys/{id}` | Revoke an API key |
| `GET` | `/api-keys` | List API keys |

### Real-time Sync

| Protocol | Endpoint | Description |
|----------|----------|-------------|
| WebSocket | `/socket/websocket` | Phoenix Channel — join `sync:{user_id}` for bidirectional sync |

### System

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/health` | Liveness check |
| `GET` | `/health/deep` | Checks PostgreSQL, Qdrant, embedding backend |

All endpoints except `/health`, `/register`, and `/login` require `Authorization: Bearer <api_key>` header.

## Testing

```bash
# Unit tests
mix test

# E2E sync tests (requires Docker Compose stack + Obsidian)
python3 -m pytest e2e/tests/ -v
```

See `docs/context/testing-strategy.md` for the full testing strategy.

## Production Deployment

Engram deploys to [Fly.io](https://fly.io) with first-class Phoenix support:

```bash
fly launch              # Auto-detects Phoenix, generates Dockerfile + fly.toml
fly postgres create     # Managed PostgreSQL with daily snapshots
fly storage create      # Tigris S3 for attachments
fly secrets set ...     # Voyage API key, Qdrant URL, JWT secret
fly deploy              # Runs migrations, rolling deploy
```

See `docs/context/production-deployment.md` for full infrastructure details.

## License

Engram is **dual-licensed**.

- For individuals and organizations that satisfy the Small Business clause
  (fewer than 100 total employees + contractors, and less than $1M USD
  inflation-adjusted revenue in the prior tax year), the source code is
  available under the [PolyForm Small Business License 1.0.0](LICENSE).
- For all other organizations, a separate commercial license is required.
  See [LICENSE-COMMERCIAL.md](LICENSE-COMMERCIAL.md) or email
  `support@engram.page`.

Contributions are accepted under the
[Engram Contributor License Agreement](.github/CLA.md). See
[CONTRIBUTING.md](CONTRIBUTING.md).

Copyright (c) 2026 Rasbandit Software Solutions LLC d/b/a Engram.
