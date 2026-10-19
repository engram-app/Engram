# Attachment upload refusal chain (slow 402/413/415 on POST /api/attachments)

_Last verified: 2026-10-19 against prod (`api.engram.page`). Fixes: Engram#2054
(backend telemetry + early refusal), Engram-obsidian#609 (plugin retry/fallback)._

## When you need this

- `engram-prod-alb-target-p95` fires (seconds, not ms) while CPU is flat.
- `POST /api/attachments` shows 402/413/415 in Cloudflare but you cannot find
  the 413s in PromEx route metrics or the request log.
- You are touching attachment size limits, `rawRefused()` in the plugin, or
  the JSON body cap in `endpoint.ex`.

## What happened (2026-10-19)

- Alarm `engram-prod-alb-target-p95` at 15-18s, 11:30-11:34Z. Web CPU flat
  (~0.04-0.075 cores). Every other route p95 < 220 ms.
- Cause: ONE Windows Obsidian device bulk-uploading attachments. Cloudflare,
  since 10:30Z on `POST /api/attachments`: 250x402, 85x200, 49x415, 47x413.
- The 200s took ~200 ms. The refusals were the slow ones: 402 12-13s,
  413 15-26s, 415 up to ~3s. The server refused AFTER reading the whole body.

## The chain

1. Plugin `rawRefused()` (`src/api.ts`) got a 415 whose body it could not
   identify and flipped to base64 JSON uploads for the rest of the session.
   Root cause of the unreadable body is unconfirmed; suspect Obsidian
   `requestUrl` dropping error bodies on desktop.
2. JSON bodies go through `Plug.Parsers`, capped at `@max_body_bytes`
   11_000_000 in `lib/engram_web/endpoint.ex`. Base64 inflates 4/3, so any file
   over ~8.2 MB dies as `Plug.Parsers.RequestTooLargeError` (413).
3. That parser 413 has NO `http.route`: it never reaches PromEx route metrics
   or the request log line. Only Tempo and Cloudflare see it.
4. Plugin retried 413/415/402 forever, so each file re-uploaded its full body
   on every sync.

## Limits that disagree

| Layer | Limit |
|-------|-------|
| Plan `max_file_bytes` (`lib/engram/billing/limit_keys.ex`) | Free 10 MiB, Starter 200 MiB, Pro 500 MiB |
| JSON request path (`endpoint.ex`) | 11 MB (~8.2 MB file after base64) |
| Cloudflare on `api.engram.page` | 100 MB body |

- Free can never get a 413 from the plan check (10,485,760 < ceiling); the
  plan check answers `402 file_too_large`.
- Free is text-only for attachments: non-text gets 402.
- Starter/Pro limits above 100 MB are unreachable through Cloudflare today.

## Fixes

- **Backend #2054:** refusal span attributes + `reject_meta` on the request log
  line (plan, reason, declared bytes, `raw|json`, plugin version). A
  `BodyParser` wrapper logs/tags the parser 413 and refuses declared-oversize
  bodies before reading them. Raw path checks storage quota against the
  declared length before reading.
- **Plugin #609:** logs refusal status/body on fallback; falls back to JSON only
  on provable no-raw; parks 413/415/402 until the file or plan changes; Sync
  Center `too_large` hint no longer says 5 MB.
- **Next:** direct-to-S3 presigned uploads. Design in the Engram vault at
  `50 Engineering/_Superpowers Specs/2026-10-19-presigned-attachment-uploads-design.md`.
  Blocker: per-user DEK AES-GCM encryption is single-shot in memory on 2 GiB
  tasks. Phase 1 = 64 MiB direct; phase 2 = chunked encryption.

## Recipes

- **Parser 413s (no route):** Tempo `{ span.http.response.status_code = 413 }`;
  look for `error.type` `Plug.Parsers.RequestTooLargeError`.
- **Slow or refused uploads:** Tempo
  `{ span.http.route = "/api/attachments" && (duration > 2s || span.http.response.status_code >= 400) }`.
  Default search returns only 20 traces, so filter by status, not just route.
- **Edge counts:** Cloudflare GraphQL via Grafana datasource
  `infinity-cloudflare` (recipe in workspace
  `docs/context/cloudflare-early-hints-504-noise.md`), filter
  `clientRequestPath: "/api/attachments"`, dims `edgeResponseStatus`,
  `originResponseStatus`.
- **Prod web CPU:** on `grafanacloud-prom`,
  `sum by (role) (rate(ecs_task_cpu_usage_total_Nanoseconds[5m]))/1e9`.
  `process_cpu_seconds_total` is the homelab, not prod.
- **Client logs for one device:** Loki
  `{service_name="engram", env="prod"} |= "<device_id>"`; plugin messages are
  prefixed `[client:api]`.
- **Which plan was the user on:** after #2054 it is on the span and the log
  line. Before that, the only route was PostHog HogQL via Grafana by hashed
  `user_id`, which returned 503 during this incident.

## Gotchas

- Flat CPU + high ALB p95 = slow request bodies, not compute. Check per-route
  p95 and Cloudflare status counts before profiling.
- A refusal that reads the full body first costs the same wire time as a
  success. Refuse on declared length (`content-length`) wherever possible.
