# Ordered Cursor Sync — PR B3 (web) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate the React web SPA onto the ordered cursor feed so it reliably converges with other devices, including across socket downtime — as a gap-filler beside the live Phoenix socket.

**Architecture:** The web has **no durable local mirror** — it renders notes/folders from the server on demand and keeps an in-memory React Query cache, invalidated live by the Phoenix socket. B3 adds the cursor pull as a *source of change signals* (not data, not a mirror): on first load it seeds a per-vault cursor from the manifest's `change_seq`; on socket-reconnect and window-focus it pulls `seq > cursor` **metadata-only** rows and feeds each note row into the existing `handleNoteChanged` invalidation pipeline (same one the socket drives). The socket stays the latency accelerator; the cursor pull is the durable convergence path. No offline queue, no three-way reconcile (web has no baseline). This also lays the foundation for a future PWA (swap invalidate→write-to-IndexedDB in one place).

**Tech Stack:** Elixir/Phoenix (backend `?fields=meta` passthrough), React + TypeScript + Vite + Vitest + `@tanstack/react-query` + `phoenix` JS client (frontend, in `backend/frontend/` of the engram repo).

---

## Context for the implementer (read before starting)

- **Backend changes endpoint** lives at `lib/engram_web/controllers/sync_controller.ex`. `changes/2` (line 43) already reads `x-device-id`, decodes the opaque cursor, and calls `render_changes/6` (line 58) which queries notes ∪ attachments by `(seq,id)`. It currently **never passes `fields`**, so notes always return full (decrypted) content. The data layer `Engram.Notes.list_changes_by_seq/4` (`lib/engram/notes.ex:1585`) **already supports** `fields: :meta` (projects out `content_ciphertext`, returns `content: nil`, keeps `content_hash`). Task 1 exposes it via a query param.
- **Meta rows are decrypted server-side** (`notes.ex:1626` `decrypt_or_raise!` → `change_map`): each row carries decrypted `id`, `path`, `folder`, `title`, `tags`, `deleted`, `content_hash`, `seq`, and `content: nil`. The controller tags each with `type: "note" | "attachment"`. So the web gets everything it needs to invalidate by note id + folder — no ciphertext, no extra decrypt.
- **Cursor codec** (`lib/engram/sync.ex:10`): `encode_cursor(seq, id) = Base.url_encode64("#{seq}:#{id}", padding: false)`. The client must byte-match this. Decode validates `id` as a UUID, so the head sentinel must be a valid UUID (`MAX_UUID = "ffffffff-ffff-ffff-ffff-ffffffffffff"`).
- **Manifest** (`sync_controller.ex:130`) returns `change_seq: Engram.Vaults.current_seq(...)` — the head seq used to seed a fresh device's cursor so the first pull returns only future changes.
- **Frontend central fetch wrapper**: `frontend/src/api/client.ts` `authFetch` (line 41) sets `Content-Type`, `Authorization`, and `X-Vault-ID` (line 51). `X-Device-Id` is added beside `X-Vault-ID`.
- **localStorage pattern to mirror**: `frontend/src/api/active-vault.ts` (key `engram.activeVaultId`, try/catch read/write).
- **Invalidation pipeline to reuse**: `frontend/src/api/channel.ts` `handleNoteChanged(payload, queryClient, activeVaultId)` (line 108) — per-note key invalidation (immediate) + coalesced folder/search invalidation (250ms window). It already handles delete events (derives folder from path when `folder` omitted) and guards cross-vault payloads. Cursor rows map directly into its `NoteChangedPayload` shape (`{ event_type, vault_id, id, path, folder }`).
- **Socket lifecycle**: `frontend/src/api/channel.ts` `connectChannel` (line 179) owns the phoenix `Socket`; `frontend/src/api/use-channel.ts` is the React hook that connects on `user`+`vaultId`. The phoenix `Socket` exposes `onOpen(cb)` which fires on initial connect **and every reconnect** — that's the reconnect trigger hook.
- **Attachments**: the web takes **no UI action** on attachment-type rows (parity with the socket, which carries no attachment event — `channel.ts` only listens for `note_changed`/`notes.batch`). The cursor still advances past them.
- **Tests**: Vitest unit, colocated `*.test.ts(x)`. Backend `mix test`. `@testing-library/react` + `renderHook` available; `phoenix` is mockable via `vi.mock('phoenix')`.

**Worktree:** `engram/.worktrees/sync-b3-web` on branch `feat/sync-cursor-pull-b3-web` (off `origin/main`). Deps already hardlinked by the post-checkout hook — do NOT run `mix deps.get` / `bun install`.

**Baseline before starting:** run `cd frontend && bun run test` and `mix test test/engram_web/controllers/sync_changes_test.exs` — confirm green before Task 1.

---

### Task 1: Backend — expose `?fields=meta` on `/sync/changes`

**Files:**
- Modify: `lib/engram_web/controllers/sync_controller.ex` (`changes/2` line 43; `render_changes/6` line 58)
- Test: `test/engram_web/controllers/sync_changes_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to `test/engram_web/controllers/sync_changes_test.exs`, inside the module (after the existing `manifest includes current change_seq` test):

```elixir
  test "fields=meta omits note content but keeps content_hash + path", %{
    conn: conn,
    user: user,
    vault: vault
  } do
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "n.md", "content" => "secret body"})

    body = conn |> get(~p"/api/sync/changes?fields=meta") |> json_response(200)
    note = Enum.find(body["changes"], &(&1["type"] == "note"))

    assert note["content"] == nil
    assert is_binary(note["content_hash"])
    assert note["path"] == "n.md"
  end

  test "default (no fields param) returns full note content", %{
    conn: conn,
    user: user,
    vault: vault
  } do
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "n.md", "content" => "secret body"})

    body = conn |> get(~p"/api/sync/changes") |> json_response(200)
    note = Enum.find(body["changes"], &(&1["type"] == "note"))

    assert note["content"] == "secret body"
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/engram_web/controllers/sync_changes_test.exs -t fields`
(or run the whole file)
Expected: the `fields=meta omits note content` test FAILS — `note["content"]` is the decrypted body, not `nil`, because the controller ignores `fields`.

- [ ] **Step 3: Thread `fields` through the controller**

In `lib/engram_web/controllers/sync_controller.ex`, update `changes/2` to parse the param and pass it down:

```elixir
  def changes(conn, params) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault
    device_id = conn |> get_req_header("x-device-id") |> List.first()
    limit = parse_limit(params["limit"])
    fields = parse_fields(params["fields"])

    case Engram.Sync.decode_cursor(params["cursor"]) do
      {:ok, cursor} ->
        render_changes(conn, user, vault, device_id, cursor || {0, nil}, limit, fields)

      {:error, :invalid_cursor} ->
        conn |> put_status(400) |> json(%{error: "invalid_cursor"})
    end
  end
```

Update `render_changes/6` to `render_changes/7`, threading `fields` into the **notes** feed only (attachments carry no content to strip). Change the head and the notes query call:

```elixir
  defp render_changes(conn, user, vault, device_id, {after_seq, after_id}, limit, fields) do
    if after_seq < Engram.Sync.retention_floor(vault) do
      conn |> put_status(410) |> json(%{error: "history_expired"})
    else
      {:ok, %{changes: notes, has_more: notes_more}} =
        Engram.Notes.list_changes_by_seq(user, vault, after_seq,
          after_id: after_id,
          limit: limit + 1,
          fields: fields
        )

      {:ok, %{changes: atts, has_more: atts_more}} =
        Engram.Attachments.list_changes_by_seq(user, vault, after_seq,
          after_id: after_id,
          limit: limit + 1
        )
```

(Leave the rest of `render_changes` — merge, paginate, `record_cursor`, `json` — unchanged.)

Add the `parse_fields/1` helper near `parse_limit/1`:

```elixir
  defp parse_fields("meta"), do: :meta
  defp parse_fields(_), do: :all
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/engram_web/controllers/sync_changes_test.exs`
Expected: PASS (all tests, including the two new ones and the existing pagination/watermark/change_seq tests).

- [ ] **Step 5: Commit**

```bash
git add lib/engram_web/controllers/sync_controller.ex test/engram_web/controllers/sync_changes_test.exs
git commit -m "feat(sync): expose ?fields=meta on /sync/changes for signal-only pulls"
```

---

### Task 2: Frontend — `device-id` module (mint + persist)

**Files:**
- Create: `frontend/src/api/device-id.ts`
- Test: `frontend/src/api/device-id.test.ts`

- [ ] **Step 1: Write the failing test**

Create `frontend/src/api/device-id.test.ts`:

```ts
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { getDeviceId, __resetDeviceIdCache } from './device-id'

describe('getDeviceId', () => {
  beforeEach(() => {
    localStorage.clear()
    __resetDeviceIdCache()
  })
  afterEach(() => {
    localStorage.clear()
    __resetDeviceIdCache()
  })

  it('mints a UUID and persists it to localStorage', () => {
    const id = getDeviceId()
    expect(id).toMatch(/^[0-9a-f-]{36}$/)
    expect(localStorage.getItem('engram.deviceId')).toBe(id)
  })

  it('returns the same id across calls (stable)', () => {
    expect(getDeviceId()).toBe(getDeviceId())
  })

  it('reads an existing id from storage rather than minting a new one', () => {
    getDeviceId()
    const stored = localStorage.getItem('engram.deviceId')
    __resetDeviceIdCache()
    expect(getDeviceId()).toBe(stored)
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd frontend && bun run test src/api/device-id.test.ts`
Expected: FAIL — cannot resolve `./device-id`.

- [ ] **Step 3: Write the implementation**

Create `frontend/src/api/device-id.ts`:

```ts
const STORAGE_KEY = 'engram.deviceId'

let deviceId: string | null = null

function readStored(): string | null {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    return raw && raw.length > 0 ? raw : null
  } catch {
    return null
  }
}

function writeStored(id: string): void {
  try {
    localStorage.setItem(STORAGE_KEY, id)
  } catch {
    // ignore — private browsing, storage disabled, etc.
  }
}

/**
 * Stable random per-install device id (UUID), minted once and persisted in
 * localStorage. Sent as `X-Device-Id` so the backend can attribute a sync
 * watermark to this browser. A localStorage clear / new browser mints a fresh
 * id → one clean re-bootstrap (safe by design — the web has no local mirror).
 */
export function getDeviceId(): string {
  if (deviceId) return deviceId
  deviceId = readStored() ?? crypto.randomUUID()
  writeStored(deviceId)
  return deviceId
}

/** Test hook: drop the in-memory cache so the next read re-reads storage. */
export function __resetDeviceIdCache(): void {
  deviceId = null
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd frontend && bun run test src/api/device-id.test.ts`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add frontend/src/api/device-id.ts frontend/src/api/device-id.test.ts
git commit -m "feat(web): mint + persist per-install device_id"
```

---

### Task 3: Frontend — send `X-Device-Id` from `authFetch`

**Files:**
- Modify: `frontend/src/api/client.ts:49-52` (after the `X-Vault-ID` block in `authFetch`)
- Test: `frontend/src/api/client.test.ts`

- [ ] **Step 1: Write the failing test**

Append to `frontend/src/api/client.test.ts`, inside the existing `describe`:

```ts
  it("sends an X-Device-Id header on every request", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValue(new Response("{}", { status: 200 }))
    globalThis.fetch = fetchMock

    await api.get("/anything")

    const init = fetchMock.mock.calls[0][1] as RequestInit
    const headers = init.headers as Headers
    expect(headers.get("X-Device-Id")).toMatch(/^[0-9a-f-]{36}$/)
  })
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd frontend && bun run test src/api/client.test.ts`
Expected: FAIL — `headers.get("X-Device-Id")` is `null` (header not set yet).

- [ ] **Step 3: Wire the header into `authFetch`**

In `frontend/src/api/client.ts`, add the import at the top (beside the `getActiveVaultId` import):

```ts
import { getDeviceId } from './device-id'
```

Then in `authFetch`, after the `X-Vault-ID` block (line 49-52), add:

```ts
  headers.set('X-Device-Id', getDeviceId())
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd frontend && bun run test src/api/client.test.ts`
Expected: PASS (existing 402 tests + the new header test).

- [ ] **Step 5: Commit**

```bash
git add frontend/src/api/client.ts frontend/src/api/client.test.ts
git commit -m "feat(web): send X-Device-Id header on all API requests"
```

---

### Task 4: Frontend — cursor codec + per-vault storage (`cursor.ts`)

**Files:**
- Create: `frontend/src/api/cursor.ts`
- Test: `frontend/src/api/cursor.test.ts`

- [ ] **Step 1: Write the failing test**

Create `frontend/src/api/cursor.test.ts`:

```ts
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { MAX_UUID, encodeCursor, getCursor, setCursor } from './cursor'

function decodeUrlB64(tok: string): string {
  return atob(tok.replace(/-/g, '+').replace(/_/g, '/'))
}

describe('encodeCursor', () => {
  it('matches the backend codec: url-safe base64 of "<seq>:<id>", no padding', () => {
    const tok = encodeCursor(42, MAX_UUID)
    // round-trips to the exact "<seq>:<id>" payload the backend encodes
    expect(decodeUrlB64(tok)).toBe(`42:${MAX_UUID}`)
    // url-safe alphabet, no '+' '/' '=' (backend uses padding: false)
    expect(tok).not.toMatch(/[+/=]/)
  })

  it('uses an all-f UUID sentinel for the head cursor', () => {
    expect(MAX_UUID).toBe('ffffffff-ffff-ffff-ffff-ffffffffffff')
  })
})

describe('cursor storage', () => {
  beforeEach(() => localStorage.clear())
  afterEach(() => localStorage.clear())

  it('returns null when no cursor is stored for the vault', () => {
    expect(getCursor('v1')).toBeNull()
  })

  it('persists and reads back a cursor per vault', () => {
    setCursor('v1', 'tok-1')
    setCursor('v2', 'tok-2')
    expect(getCursor('v1')).toBe('tok-1')
    expect(getCursor('v2')).toBe('tok-2')
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd frontend && bun run test src/api/cursor.test.ts`
Expected: FAIL — cannot resolve `./cursor`.

- [ ] **Step 3: Write the implementation**

Create `frontend/src/api/cursor.ts`:

```ts
/** Head-cursor id sentinel. Larger than any real UUID, so seeding the cursor to
 *  `(change_seq, MAX_UUID)` makes the first pull return only `seq > change_seq`
 *  (rows AT change_seq are already rendered by the normal queries). Must be a
 *  valid UUID — the backend decode validates `id` via Ecto.UUID.cast. */
export const MAX_UUID = 'ffffffff-ffff-ffff-ffff-ffffffffffff'

/** Mirror of backend `Engram.Sync.encode_cursor/2`: url-safe base64 of
 *  "<seq>:<id>" with padding stripped. seq+uuid are ASCII, so btoa is safe. */
export function encodeCursor(seq: number, id: string): string {
  return btoa(`${seq}:${id}`)
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '')
}

// Per-vault: `seq` is vault-scoped, so each vault tracks its own cursor.
function cursorKey(vaultId: string): string {
  return `engram.syncCursor.${vaultId}`
}

export function getCursor(vaultId: string): string | null {
  try {
    const raw = localStorage.getItem(cursorKey(vaultId))
    return raw && raw.length > 0 ? raw : null
  } catch {
    return null
  }
}

export function setCursor(vaultId: string, cursor: string): void {
  try {
    localStorage.setItem(cursorKey(vaultId), cursor)
  } catch {
    // ignore — private browsing, storage disabled, etc.
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd frontend && bun run test src/api/cursor.test.ts`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add frontend/src/api/cursor.ts frontend/src/api/cursor.test.ts
git commit -m "feat(web): cursor codec (backend-parity) + per-vault cursor storage"
```

---

### Task 5: Frontend — cursor-sync engine (`cursor-sync.ts`)

The core: bootstrap a fresh device's cursor from the manifest; pull deltas and feed note rows into `handleNoteChanged`; single-flight per vault; reseed on a stale-cursor 400/410; and a DI-friendly trigger installer.

**Files:**
- Create: `frontend/src/api/cursor-sync.ts`
- Test: `frontend/src/api/cursor-sync.test.ts`

- [ ] **Step 1: Write the failing test**

Create `frontend/src/api/cursor-sync.test.ts`:

```ts
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { QueryClient } from '@tanstack/react-query'

vi.mock('./client', () => ({
  api: { get: vi.fn() },
  ApiError: class ApiError extends Error {
    constructor(
      public status: number,
      message: string,
    ) {
      super(message)
    }
  },
}))

import { api, ApiError } from './client'
import { __resetNoteChangeBatch } from './channel'
import { getCursor, setCursor, encodeCursor, MAX_UUID } from './cursor'
import {
  runCursorSync,
  __resetCursorSyncInflight,
  installCursorSyncTriggers,
} from './cursor-sync'

const get = api.get as unknown as ReturnType<typeof vi.fn>

function mockQueryClient() {
  return {
    invalidateQueries: vi.fn(),
    getQueryData: vi.fn(() => undefined),
  } as unknown as QueryClient & { invalidateQueries: ReturnType<typeof vi.fn> }
}

beforeEach(() => {
  localStorage.clear()
  get.mockReset()
  __resetCursorSyncInflight()
  vi.useFakeTimers()
})
afterEach(() => {
  __resetNoteChangeBatch()
  vi.useRealTimers()
  localStorage.clear()
})

describe('runCursorSync — bootstrap (no stored cursor)', () => {
  it('seeds the cursor from the manifest change_seq and applies nothing', async () => {
    get.mockResolvedValueOnce({ change_seq: 7 })
    const qc = mockQueryClient()

    await runCursorSync('v1', qc)

    expect(get).toHaveBeenCalledTimes(1)
    expect(get).toHaveBeenCalledWith('/sync/manifest')
    expect(getCursor('v1')).toBe(encodeCursor(7, MAX_UUID))
    expect(qc.invalidateQueries).not.toHaveBeenCalled()
  })
})

describe('runCursorSync — incremental pull (cursor present)', () => {
  it('pulls fields=meta, invalidates per changed note, and advances the cursor', async () => {
    setCursor('v1', 'tok-0')
    get.mockResolvedValueOnce({
      changes: [
        { type: 'note', id: 'id-1', path: 'docs/a.md', folder: 'docs', deleted: false, seq: 5 },
      ],
      next_cursor: null,
      has_more: false,
    })
    const qc = mockQueryClient()

    await runCursorSync('v1', qc)

    expect(get).toHaveBeenCalledWith('/sync/changes?cursor=tok-0&fields=meta')
    // per-note key invalidates synchronously
    expect(qc.invalidateQueries).toHaveBeenCalledWith({ queryKey: ['note', 'v1', 'id-1'] })
    // final non-empty page → cursor advances to the last applied row
    expect(getCursor('v1')).toBe(encodeCursor(5, 'id-1'))
  })

  it('follows has_more across pages using next_cursor', async () => {
    setCursor('v1', 'tok-0')
    get
      .mockResolvedValueOnce({
        changes: [{ type: 'note', id: 'id-1', path: 'a.md', seq: 1 }],
        next_cursor: 'tok-1',
        has_more: true,
      })
      .mockResolvedValueOnce({
        changes: [{ type: 'note', id: 'id-2', path: 'b.md', seq: 2 }],
        next_cursor: null,
        has_more: false,
      })
    const qc = mockQueryClient()

    await runCursorSync('v1', qc)

    expect(get).toHaveBeenNthCalledWith(1, '/sync/changes?cursor=tok-0&fields=meta')
    expect(get).toHaveBeenNthCalledWith(2, '/sync/changes?cursor=tok-1&fields=meta')
    expect(getCursor('v1')).toBe(encodeCursor(2, 'id-2'))
  })

  it('takes no UI action on attachment rows but still advances past them', async () => {
    setCursor('v1', 'tok-0')
    get.mockResolvedValueOnce({
      changes: [{ type: 'attachment', id: 'att-1', path: 'img/x.png', seq: 9 }],
      next_cursor: null,
      has_more: false,
    })
    const qc = mockQueryClient()

    await runCursorSync('v1', qc)
    vi.advanceTimersByTime(250)

    expect(qc.invalidateQueries).not.toHaveBeenCalled()
    expect(getCursor('v1')).toBe(encodeCursor(9, 'att-1'))
  })

  it('leaves the cursor unchanged on an empty page', async () => {
    setCursor('v1', 'tok-0')
    get.mockResolvedValueOnce({ changes: [], next_cursor: null, has_more: false })
    const qc = mockQueryClient()

    await runCursorSync('v1', qc)

    expect(getCursor('v1')).toBe('tok-0')
  })

  it('reseeds from the manifest when the stored cursor is stale (410)', async () => {
    setCursor('v1', 'stale-tok')
    get
      .mockRejectedValueOnce(new (ApiError as never)(410, 'history_expired'))
      .mockResolvedValueOnce({ change_seq: 12 })
    const qc = mockQueryClient()

    await runCursorSync('v1', qc)

    expect(getCursor('v1')).toBe(encodeCursor(12, MAX_UUID))
  })
})

describe('runCursorSync — single-flight per vault', () => {
  it('coalesces concurrent runs for the same vault into one', async () => {
    setCursor('v1', 'tok-0')
    let resolve!: (v: unknown) => void
    get.mockReturnValueOnce(new Promise((r) => (resolve = r)))
    const qc = mockQueryClient()

    const a = runCursorSync('v1', qc)
    const b = runCursorSync('v1', qc)

    resolve({ changes: [], next_cursor: null, has_more: false })
    await Promise.all([a, b])

    expect(get).toHaveBeenCalledTimes(1)
  })
})

describe('installCursorSyncTriggers', () => {
  it('runs immediately, on window focus, and stops after cleanup', () => {
    const run = vi.fn()
    const qc = mockQueryClient()

    const cleanup = installCursorSyncTriggers('v1', qc, run)
    expect(run).toHaveBeenCalledTimes(1)

    window.dispatchEvent(new Event('focus'))
    expect(run).toHaveBeenCalledTimes(2)

    cleanup()
    window.dispatchEvent(new Event('focus'))
    expect(run).toHaveBeenCalledTimes(2)
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd frontend && bun run test src/api/cursor-sync.test.ts`
Expected: FAIL — cannot resolve `./cursor-sync`.

- [ ] **Step 3: Write the implementation**

Create `frontend/src/api/cursor-sync.ts`:

```ts
import type { QueryClient } from '@tanstack/react-query'
import { api, ApiError } from './client'
import { handleNoteChanged, type NoteChangedPayload } from './channel'
import { encodeCursor, getCursor, setCursor, MAX_UUID } from './cursor'

interface ChangeRow {
  type: 'note' | 'attachment'
  id: string
  path: string
  folder?: string
  deleted?: boolean
  seq: number
}

interface ChangesPage {
  changes: ChangeRow[]
  next_cursor: string | null
  has_more: boolean
}

interface ManifestHead {
  change_seq: number
}

// Backstop against a server bug returning has_more:true forever.
const MAX_PAGES = 10_000

// Single-flight: reconnect + focus can fire together; one run per vault.
const inflight = new Map<string, Promise<void>>()

/**
 * Reconcile this device against the ordered change feed. On a fresh device
 * (no stored cursor) it seeds the cursor at the manifest head and applies
 * nothing (current state is already on screen via the normal queries). With a
 * cursor it pulls metadata-only deltas and feeds each note row through the
 * socket's invalidation pipeline. Single-flight per vault.
 */
export function runCursorSync(vaultId: string, queryClient: QueryClient): Promise<void> {
  const existing = inflight.get(vaultId)
  if (existing) return existing
  const run = doCursorSync(vaultId, queryClient).finally(() => inflight.delete(vaultId))
  inflight.set(vaultId, run)
  return run
}

async function doCursorSync(vaultId: string, queryClient: QueryClient): Promise<void> {
  const cursor = getCursor(vaultId)
  if (cursor == null) {
    setCursor(vaultId, await bootstrap())
    return
  }
  try {
    await pullLoop(vaultId, cursor, queryClient)
  } catch (e) {
    // Stale/tampered cursor (400) or compacted history (410, dormant until
    // PR D) → re-establish a head cursor. Bootstrap re-renders nothing; the
    // normal queries already hold current state.
    if (e instanceof ApiError && (e.status === 400 || e.status === 410)) {
      setCursor(vaultId, await bootstrap())
      return
    }
    throw e
  }
}

async function bootstrap(): Promise<string> {
  const head = await api.get<ManifestHead>('/sync/manifest')
  return encodeCursor(head.change_seq, MAX_UUID)
}

async function pullLoop(
  vaultId: string,
  startCursor: string,
  queryClient: QueryClient,
): Promise<void> {
  let cursor = startCursor
  for (let i = 0; i < MAX_PAGES; i++) {
    const page = await api.get<ChangesPage>(
      `/sync/changes?cursor=${encodeURIComponent(cursor)}&fields=meta`,
    )
    for (const row of page.changes) applyRow(row, queryClient, vaultId)

    const next = nextCursor(page, cursor)
    if (next !== cursor) {
      cursor = next
      setCursor(vaultId, cursor)
    }
    if (!page.has_more) break
  }
}

// The server only sends next_cursor while has_more is true. On the final page
// we encode the head ourselves from the last applied row; an empty page keeps
// the prior cursor.
function nextCursor(page: ChangesPage, prev: string): string {
  if (page.next_cursor) return page.next_cursor
  const last = page.changes[page.changes.length - 1]
  return last ? encodeCursor(last.seq, last.id) : prev
}

// The web has no local mirror, so a change row is a *signal*: note rows reuse
// the socket's invalidation pipeline; attachment rows get no UI action (parity
// with the socket, which carries no attachment event) but the cursor advances.
function applyRow(row: ChangeRow, queryClient: QueryClient, vaultId: string): void {
  if (row.type !== 'note') return
  const payload: NoteChangedPayload = {
    event_type: row.deleted ? 'delete' : 'upsert',
    vault_id: vaultId,
    id: row.id,
    path: row.path,
    folder: row.folder,
  }
  handleNoteChanged(payload, queryClient, vaultId)
}

/**
 * Install the cursor-sync triggers: run once now, then on every window focus.
 * (Socket reconnect is wired separately via connectChannel's onSocketOpen.)
 * Returns a cleanup that removes the focus listener. `run` is injectable for
 * tests; production uses the default runCursorSync.
 */
export function installCursorSyncTriggers(
  vaultId: string,
  queryClient: QueryClient,
  run: (vaultId: string, queryClient: QueryClient) => void = runCursorSync,
): () => void {
  run(vaultId, queryClient)
  const onFocus = () => run(vaultId, queryClient)
  window.addEventListener('focus', onFocus)
  return () => window.removeEventListener('focus', onFocus)
}

/** Test hook: drop any in-flight single-flight entries. */
export function __resetCursorSyncInflight(): void {
  inflight.clear()
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd frontend && bun run test src/api/cursor-sync.test.ts`
Expected: PASS (all describe blocks).

- [ ] **Step 5: Commit**

```bash
git add frontend/src/api/cursor-sync.ts frontend/src/api/cursor-sync.test.ts
git commit -m "feat(web): cursor-sync engine — bootstrap, delta pull, single-flight, reseed"
```

---

### Task 6: Frontend — wire triggers (socket reconnect + mount/focus)

Add an `onSocketOpen` hook to `connectChannel` (fires on initial connect + every reconnect), and have `useChannel` install the focus/mount triggers and pass `onSocketOpen` → `runCursorSync`.

**Files:**
- Modify: `frontend/src/api/channel.ts` (`ConnectOptions` line 9; `connectChannel` line 179)
- Modify: `frontend/src/api/use-channel.ts`
- Test: `frontend/src/api/channel-onopen.test.ts` (new)

- [ ] **Step 1: Write the failing test**

Create `frontend/src/api/channel-onopen.test.ts`:

```ts
import { afterEach, describe, expect, it, vi } from 'vitest'

// Minimal phoenix mock: capture the onOpen callback and the channel handlers.
const onOpen = vi.fn()
const channelOn = vi.fn()
const join = vi.fn(() => ({ receive: () => ({ receive: () => {} }) }))

vi.mock('phoenix', () => ({
  Socket: vi.fn().mockImplementation(() => ({
    connect: vi.fn(),
    disconnect: vi.fn(),
    onOpen,
    channel: vi.fn(() => ({ on: channelOn, join, leave: vi.fn() })),
  })),
  Channel: vi.fn(),
}))

import { connectChannel, disconnectChannel } from './channel'

afterEach(() => {
  disconnectChannel()
  vi.clearAllMocks()
})

describe('connectChannel onSocketOpen', () => {
  it('registers onSocketOpen with the socket so reconnects can fire it', async () => {
    const onSocketOpen = vi.fn()
    const queryClient = { invalidateQueries: vi.fn() } as never

    await connectChannel({
      userId: 'u1',
      vaultId: 'v1',
      getToken: async () => 't',
      queryClient,
      onSocketOpen,
    })

    expect(onOpen).toHaveBeenCalledTimes(1)
    // Invoking the registered callback (as a reconnect would) calls our hook.
    const registered = onOpen.mock.calls[0][0] as () => void
    registered()
    expect(onSocketOpen).toHaveBeenCalledTimes(1)
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd frontend && bun run test src/api/channel-onopen.test.ts`
Expected: FAIL — `connectChannel` does not accept/register `onSocketOpen` (`onOpen` never called).

- [ ] **Step 3: Add `onSocketOpen` to `connectChannel`**

In `frontend/src/api/channel.ts`, extend `ConnectOptions` (line 9):

```ts
interface ConnectOptions {
  userId: string
  vaultId: string
  getToken: () => Promise<string | null>
  queryClient: QueryClient
  onSocketOpen?: () => void
}
```

In `connectChannel` (line 179), destructure the new option and register it right after `socket.connect()`:

```ts
export async function connectChannel({
  userId,
  vaultId,
  getToken,
  queryClient,
  onSocketOpen,
}: ConnectOptions) {
  disconnectChannel()

  const token = await getToken()

  socket = new Socket(joinWsUrl(getWsBase(), '/socket'), {
    params: { token: token ?? '' },
  })

  socket.connect()

  // Fires on initial connect AND every reconnect — the durable-feed catch-up
  // trigger. The socket can drop events while disconnected (no replay), so a
  // reconnect kicks a cursor pull to backfill the gap.
  if (onSocketOpen) socket.onOpen(onSocketOpen)
```

(Leave the rest of `connectChannel` unchanged.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd frontend && bun run test src/api/channel-onopen.test.ts`
Expected: PASS.

- [ ] **Step 5: Wire `useChannel` to install triggers + pass `onSocketOpen`**

Replace the body of `frontend/src/api/use-channel.ts` with:

```ts
import { useEffect } from 'react'
import { useAuthAdapter } from '../auth/use-auth-adapter'
import { connectChannel, disconnectChannel } from './channel'
import { runCursorSync, installCursorSyncTriggers } from './cursor-sync'
import { queryClient } from './query-client'
import { useMe } from './queries'
import { useActiveVaultId } from './active-vault'

export function useChannel() {
  const { getToken } = useAuthAdapter()
  const { data: user } = useMe()
  const vaultId = useActiveVaultId()

  useEffect(() => {
    if (!user || vaultId == null) return

    connectChannel({
      userId: user.id,
      vaultId,
      getToken: () => getToken(),
      queryClient,
      // Reconnect (and initial connect) → backfill missed changes via the
      // durable cursor feed. Single-flight dedupes against the mount run below.
      onSocketOpen: () => runCursorSync(vaultId, queryClient),
    })

    // Run on mount + on every window focus; returns a listener cleanup.
    const removeTriggers = installCursorSyncTriggers(vaultId, queryClient)

    return () => {
      disconnectChannel()
      removeTriggers()
    }
  }, [user?.id, vaultId, getToken])
}
```

- [ ] **Step 6: Run the full frontend suite to verify nothing regressed**

Run: `cd frontend && bun run test src/api/`
Expected: PASS (channel, client, cursor, cursor-sync, device-id, channel-onopen, and any existing api tests).

- [ ] **Step 7: Commit**

```bash
git add frontend/src/api/channel.ts frontend/src/api/channel-onopen.test.ts frontend/src/api/use-channel.ts
git commit -m "feat(web): trigger cursor sync on mount, window focus, and socket reconnect"
```

---

### Task 7: Version bump, build, and full verification

**Files:**
- Modify: `mix.exs:7` (version `0.5.453` → `0.5.454`)

- [ ] **Step 1: Bump the backend version**

The `version-check` CI gate requires a `mix.exs` bump on any engram PR that touches backend code (Task 1 does). In `mix.exs`, change:

```elixir
      version: "0.5.453",
```
to:
```elixir
      version: "0.5.454",
```

- [ ] **Step 2: Run the backend tests touched by this PR**

Run: `mix test test/engram_web/controllers/sync_changes_test.exs`
Expected: PASS.

- [ ] **Step 3: Run the full frontend unit suite**

Run: `cd frontend && bun run test`
Expected: PASS (no regressions across the SPA).

- [ ] **Step 4: Typecheck + production build the frontend**

Run: `cd frontend && bun run build`
Expected: `tsc --noEmit` clean, `vite build` succeeds (no type errors from the new modules / the `NoteChangedPayload` import).

- [ ] **Step 5: Commit**

```bash
git add mix.exs
git commit -m "chore: bump version to 0.5.454 (sync cursor pull B3 — web)"
```

- [ ] **Step 6: Manual real-browser verification (laptop CDP tunnel)**

Follow `docs/context/local-browser-cdp-tunnel.md`. With the SaaS-shape local stack running, in the browser:
1. Open the app; confirm `localStorage['engram.deviceId']` is set and `localStorage['engram.syncCursor.<vaultId>']` is seeded after first load.
2. In DevTools Network, confirm requests carry an `X-Device-Id` header and that a `/api/sync/changes?...&fields=meta` request fires on window refocus.
3. From a second client (plugin or a second browser), edit a note; refocus the web tab; confirm the file tree / open note updates **without a manual reload** (the focus-triggered pull replayed the change).
4. Confirm the pulled `/sync/changes` response rows carry `content: null` (metadata-only).

---

## Self-Review

**Spec coverage** (against `2026-06-16-sync-cursor-pull-design.md`, "PR B3 — web" + §A/§C/§E/§F/§H):
- §A device_id (mint + persist localStorage + `X-Device-Id`) → Tasks 2, 3. ✓
- §C keyset pull (consume `/sync/changes?cursor=`, `next_cursor`/`has_more`) → Task 5 `pullLoop`. ✓
- §E bootstrap (manifest `change_seq` → seed head cursor) + `HISTORY_EXPIRED` (410) → Task 5 `bootstrap` + 400/410 reseed. ✓ (web simpler case — applies nothing on bootstrap)
- §F reconcile → intentionally N/A for web (no baseline / no local mirror); documented in Architecture + `applyRow`. ✓
- §H coexistence (socket stays accelerator; pull is additive; legacy feed untouched) → Tasks 5/6 (socket handlers unchanged; `onSocketOpen` additive). ✓
- "manifest is truth, render it" → web renders from existing queries; cursor rows are signals → invalidations. ✓
- `fields=meta` (signal-not-data) → Task 1 (backend) + Task 5 (web requests it). ✓

**Placeholder scan:** none — every step shows concrete code/commands and expected output.

**Type consistency:**
- `runCursorSync(vaultId, queryClient)` signature consistent across Task 5 def, Task 6 `use-channel` call, and `installCursorSyncTriggers`' `run` default.
- `ChangeRow` fields (`type`/`id`/`path`/`folder`/`deleted`/`seq`) map to `NoteChangedPayload` (`event_type`/`vault_id`/`id`/`path`/`folder`) in `applyRow`, matching `handleNoteChanged`'s existing payload shape (`channel.ts:16`).
- `encodeCursor`/`MAX_UUID`/`getCursor`/`setCursor` names identical between `cursor.ts` (Task 4) and `cursor-sync.ts` (Task 5).
- Backend `render_changes/7` arity bumped consistently at the single call site in `changes/2`.

**Scope check:** single PR, single repo (engram). One `mix.exs` bump (Task 7). No migration → no `phase/*` label. Frontend-heavy with one small backend passthrough. Focused.
```
