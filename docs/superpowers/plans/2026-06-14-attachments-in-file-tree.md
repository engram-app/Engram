# Attachments in the Web File Tree — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show image/PDF (and other binary) attachments in the web SPA file tree and let users click to open a read-only preview.

**Architecture:** A new `GET /api/attachments` lists vault attachment metadata; the existing `GET /api/attachments/*path` gains a `?raw=1` mode that streams real bytes (fixing the latent `AttachmentImg` bug). The frontend tree loader buckets attachments into their folders by path, synthesizing any folder that exists only because it holds attachments, and renders each as a `<Link>` to a new `/attachment/*` preview page.

**Tech Stack:** Elixir/Phoenix + ExUnit (backend); React + react-router + @tanstack/react-query + @headless-tree + Vite + bun test (frontend).

**Repo / worktree:** `engram/.worktrees/attachments-in-tree`, branch `feat/attachments-in-file-tree`. Single PR (backend + frontend).

**Commands:**
- Backend single test: `mix test path/to/test.exs:LINE`
- Backend all: `mix test`
- Frontend single: `bun test path/to/file.test.tsx`
- Frontend all: `bun test`
- Pre-push lints (frontend): `bun run lint:obsidian && bun run lint:css && bunx biome check .`

---

## File structure

**Backend**
- Modify `lib/engram/attachments.ex` — add `list_attachments/2`; extract a shared decrypt-map builder.
- Modify `lib/engram_web/controllers/attachments_controller.ex` — add `index/2`; add `?raw=1` branch to `show/2`.
- Modify `lib/engram_web/router.ex` — add `get "/attachments"` route (before the `*path` splat).
- Test `test/engram/attachments_test.exs`, `test/engram_web/controllers/attachments_controller_test.exs`.

**Frontend**
- Modify `frontend/src/viewer/tree/types.ts` — `attachment` TreeItem variant + id encode/decode.
- Modify `frontend/src/api/queries.ts` — `AttachmentSummary` type + `useAttachments`. (No `fetchAttachments`: the full attachment list loads eagerly via the hook — there's no per-folder lazy fetch like notes have.)
- Create `frontend/src/viewer/tree/synthesize-folders.ts` — pure helper.
- Modify `frontend/src/viewer/tree/loader.ts` — bucket attachments into folder/root children.
- Modify `frontend/src/viewer/tree/use-engram-tree.ts` — thread `attachments` into the loader + structure key.
- Modify `frontend/src/viewer/tree/tree-row.tsx` — attachment row (icon + link + badge).
- Modify `frontend/src/api/client.ts` — `getBlob` accepts optional headers (unused now, but keeps the option open) — **skip**; instead append `?raw=1` at call sites.
- Modify `frontend/src/viewer/attachment-img.tsx` — fetch with `?raw=1`.
- Create `frontend/src/viewer/attachment-page.tsx` — preview page.
- Modify `frontend/src/router.tsx` — lazy `AttachmentPage` + `/attachment/*` route.
- Modify `frontend/src/viewer/folder-tree.tsx` — `useAttachments` + `synthesizeFolders` + pass through; `onMove` target guard.
- Tests: `types.test.ts`, `synthesize-folders.test.ts`, `loader.test.ts`, `tree-row.test.tsx`, `attachment-img.test.tsx`, `attachment-page.test.tsx`.

---

## Task 1: Backend — `Attachments.list_attachments/2`

**Files:**
- Modify: `lib/engram/attachments.ex`
- Test: `test/engram/attachments_test.exs`

- [ ] **Step 1: Write the failing test**

Find the existing `list_changes` test in `test/engram/attachments_test.exs` for the setup pattern (user, vault, `upsert_attachment`). Add:

```elixir
describe "list_attachments/2" do
  test "returns non-deleted attachment metadata for the vault", %{user: user, vault: vault} do
    {:ok, _} = Attachments.upsert_attachment(user, vault, %{
      "path" => "img/a.png",
      "content_base64" => Base.encode64("PNGDATA"),
      "mime_type" => "image/png"
    })
    {:ok, b} = Attachments.upsert_attachment(user, vault, %{
      "path" => "b.pdf",
      "content_base64" => Base.encode64("PDFDATA"),
      "mime_type" => "application/pdf"
    })
    :ok = Attachments.delete_attachment(user, vault, "b.pdf")

    {:ok, list} = Attachments.list_attachments(user, vault)

    paths = Enum.map(list, & &1.path)
    assert "img/a.png" in paths
    refute "b.pdf" in paths

    a = Enum.find(list, &(&1.path == "img/a.png"))
    assert a.mime_type == "image/png"
    assert a.size_bytes == byte_size("PNGDATA")
    assert Map.has_key?(a, :updated_at)
    refute Map.has_key?(a, :deleted_at)
    # b is referenced only to assert deletion filtering
    assert b.path == "b.pdf"
  end

  test "scopes to the given user+vault", %{user: user, vault: vault} do
    other = user_fixture()
    other_vault = vault_fixture(other)
    {:ok, _} = Attachments.upsert_attachment(other, other_vault, %{
      "path" => "secret.png",
      "content_base64" => Base.encode64("X"),
      "mime_type" => "image/png"
    })

    {:ok, list} = Attachments.list_attachments(user, vault)
    refute Enum.any?(list, &(&1.path == "secret.png"))
  end
end
```

(Use the same fixture helpers the file already imports — match `user_fixture`/`vault_fixture` to the existing test's setup; if the existing test destructures `%{user: user, vault: vault}` from a `setup`, reuse it.)

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram/attachments_test.exs -k "list_attachments"`
Expected: FAIL — `function Engram.Attachments.list_attachments/2 is undefined`.

- [ ] **Step 3: Implement**

In `lib/engram/attachments.ex`, refactor `list_changes/3` to share a private mapper and add `list_attachments/2`. Replace the existing `list_changes/3` body's `Enum.map` with a call to `decrypt_metadata/2`, and add:

```elixir
@doc """
Lists non-deleted attachment metadata for a vault (no content).
"""
def list_attachments(user, vault) do
  user = fresh_user(user)

  Repo.with_tenant(user.id, fn ->
    from(a in Attachment,
      where: a.user_id == ^user.id and a.vault_id == ^vault.id and is_nil(a.deleted_at),
      order_by: [asc: a.updated_at]
    )
    |> Repo.all()
  end)
  |> unwrap_tenant()
  |> case do
    {:ok, atts} ->
      {:ok, Enum.map(atts, fn att -> Map.delete(decrypt_metadata(att, user), :deleted_at) end)}

    err ->
      err
  end
end

defp decrypt_metadata(att, user) do
  {:ok, decrypted} = Crypto.maybe_decrypt_attachment_fields(att, user)

  %{
    path: decrypted.path,
    mime_type: decrypted.mime_type,
    size_bytes: decrypted.size_bytes,
    mtime: decrypted.mtime,
    updated_at: decrypted.updated_at,
    deleted_at: decrypted.deleted_at
  }
end
```

And change `list_changes/3`'s mapper to `Enum.map(atts, &decrypt_metadata(&1, user))`.

- [ ] **Step 4: Run tests**

Run: `mix test test/engram/attachments_test.exs`
Expected: PASS (both new tests + existing `list_changes` tests still green).

- [ ] **Step 5: Commit**

```bash
git add lib/engram/attachments.ex test/engram/attachments_test.exs
git commit -m "feat(attachments): add list_attachments/2 context fn"
```

---

## Task 2: Backend — `GET /api/attachments` endpoint

**Files:**
- Modify: `lib/engram_web/controllers/attachments_controller.ex`
- Modify: `lib/engram_web/router.ex`
- Test: `test/engram_web/controllers/attachments_controller_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/engram_web/controllers/attachments_controller_test.exs` (reuse its existing authenticated-conn setup):

```elixir
describe "GET /api/attachments (index)" do
  test "lists non-deleted attachments", %{conn: conn, user: user, vault: vault} do
    {:ok, _} = Engram.Attachments.upsert_attachment(user, vault, %{
      "path" => "diagrams/arch.png",
      "content_base64" => Base.encode64("PNG"),
      "mime_type" => "image/png"
    })

    resp = conn |> get(~p"/api/attachments") |> json_response(200)

    assert [%{"path" => "diagrams/arch.png", "mime_type" => "image/png"} = a] = resp["attachments"]
    assert a["size_bytes"] == 3
    assert Map.has_key?(a, "updated_at")
  end

  test "returns empty list for a vault with no attachments", %{conn: conn} do
    resp = conn |> get(~p"/api/attachments") |> json_response(200)
    assert resp["attachments"] == []
  end

  test "401 without auth", %{vault: _vault} do
    conn = build_conn() |> get(~p"/api/attachments")
    assert conn.status in [401, 403]
  end
end
```

(Match the auth-bypass / vault-assign setup the rest of this file uses; if it uses a `register_and_log_in` style helper, reuse it for the authed cases and a bare `build_conn()` for the 401 case.)

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram_web/controllers/attachments_controller_test.exs -k "index"`
Expected: FAIL — no route for `GET /api/attachments` (likely matches the `*path` splat → 404 "attachment not found", or a `Phoenix.Router.NoRouteError`).

- [ ] **Step 3: Implement**

In `lib/engram_web/router.ex`, add the index route **before** the splat (so `/attachments` isn't captured as a path):

```elixir
    # Attachments
    post "/attachments", AttachmentsController, :upload
    get "/attachments", AttachmentsController, :index
    get "/attachments/changes", AttachmentsController, :changes
    get "/attachments/*path", AttachmentsController, :show
    delete "/attachments/*path", AttachmentsController, :delete
```

In `lib/engram_web/controllers/attachments_controller.ex`, add:

```elixir
  def index(conn, _params) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    {:ok, atts} = Attachments.list_attachments(user, vault)

    json(conn, %{
      attachments:
        Enum.map(atts, fn a ->
          %{
            path: a.path,
            mime_type: a.mime_type,
            size_bytes: a.size_bytes,
            mtime: a.mtime,
            updated_at: a.updated_at
          }
        end)
    })
  end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/engram_web/controllers/attachments_controller_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/engram_web/router.ex lib/engram_web/controllers/attachments_controller.ex test/engram_web/controllers/attachments_controller_test.exs
git commit -m "feat(attachments): GET /api/attachments list endpoint"
```

---

## Task 3: Backend — `?raw=1` raw-bytes mode on `show`

**Files:**
- Modify: `lib/engram_web/controllers/attachments_controller.ex`
- Test: `test/engram_web/controllers/attachments_controller_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
describe "GET /api/attachments/*path?raw=1" do
  test "streams raw bytes with the attachment Content-Type", %{conn: conn, user: user, vault: vault} do
    {:ok, _} = Engram.Attachments.upsert_attachment(user, vault, %{
      "path" => "p.png",
      "content_base64" => Base.encode64("RAWBYTES"),
      "mime_type" => "image/png"
    })

    conn = get(conn, ~p"/api/attachments/p.png?raw=1")

    assert conn.status == 200
    assert response_content_type(conn, :png) =~ "image/png"
    assert conn.resp_body == "RAWBYTES"
  end

  test "without raw still returns JSON with content_base64", %{conn: conn, user: user, vault: vault} do
    {:ok, _} = Engram.Attachments.upsert_attachment(user, vault, %{
      "path" => "q.png",
      "content_base64" => Base.encode64("BYTES"),
      "mime_type" => "image/png"
    })

    resp = conn |> get(~p"/api/attachments/q.png") |> json_response(200)
    assert resp["content_base64"] == Base.encode64("BYTES")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram_web/controllers/attachments_controller_test.exs -k "raw"`
Expected: FAIL — `?raw=1` request returns JSON (`conn.resp_body` is a JSON string, not `"RAWBYTES"`).

- [ ] **Step 3: Implement**

Replace the `show/2` head + its `{:ok, att}` branch in `lib/engram_web/controllers/attachments_controller.ex`:

```elixir
  def show(conn, %{"path" => path_parts} = params) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault
    path = Path.join(path_parts)

    case Attachments.get_attachment(user, vault, path) do
      {:ok, nil} ->
        conn |> put_status(404) |> json(%{error: "attachment not found"})

      {:ok, att} ->
        if params["raw"] == "1" do
          conn
          |> put_resp_content_type(att.mime_type || "application/octet-stream")
          |> send_resp(200, att.content)
        else
          json(conn, %{
            id: att.id,
            path: att.path,
            mime_type: att.mime_type,
            size_bytes: att.size_bytes,
            mtime: att.mtime,
            content_base64: Base.encode64(att.content),
            created_at: att.created_at,
            updated_at: att.updated_at
          })
        end

      {:error, {:storage, _reason}} ->
        conn |> put_status(502) |> json(%{error: "failed to fetch attachment from storage"})

      {:error, _reason} ->
        conn |> put_status(500) |> json(%{error: "internal error fetching attachment"})
    end
  end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/engram_web/controllers/attachments_controller_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/engram_web/controllers/attachments_controller.ex test/engram_web/controllers/attachments_controller_test.exs
git commit -m "feat(attachments): ?raw=1 streams attachment bytes"
```

---

## Task 4: Frontend — `attachment` TreeItem variant + id codec

**Files:**
- Modify: `frontend/src/viewer/tree/types.ts`
- Test: `frontend/src/viewer/tree/types.test.ts`

- [ ] **Step 1: Write the failing test**

Add to `frontend/src/viewer/tree/types.test.ts`:

```ts
import { formatItemId, parseItemId } from './types'

describe('attachment item ids', () => {
  it('round-trips a simple attachment path', () => {
    const id = formatItemId({ kind: 'attachment', path: 'img/a.png' })
    expect(id).toBe('a:img/a.png')
    expect(parseItemId(id)).toEqual({ kind: 'attachment', path: 'img/a.png' })
  })

  it('round-trips a path with spaces and unicode', () => {
    const path = 'My Files/diagram (final).pdf'
    const id = formatItemId({ kind: 'attachment', path })
    expect(parseItemId(id)).toEqual({ kind: 'attachment', path })
  })

  it('keeps slashes as path separators, not encoded', () => {
    const id = formatItemId({ kind: 'attachment', path: 'a/b/c.png' })
    expect(id.startsWith('a:')).toBe(true)
    expect(parseItemId(id)).toEqual({ kind: 'attachment', path: 'a/b/c.png' })
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test frontend/src/viewer/tree/types.test.ts`
Expected: FAIL — `formatItemId` rejects `kind: 'attachment'` / type error / wrong output.

- [ ] **Step 3: Implement**

In `frontend/src/viewer/tree/types.ts`:

```ts
export type TreeItem =
  | { kind: 'folder'; id: string; path: string; name: string; count: number }
  | { kind: 'note'; id: string; path: string; title: string; ext: string | null }
  | { kind: 'attachment'; path: string; mime: string; size: number }

// ...

export function formatItemId(
  input:
    | { kind: 'folder' | 'note'; id: string }
    | { kind: 'attachment'; path: string },
): ItemId {
  if (input.kind === 'attachment') {
    const encoded = input.path.split('/').map(encodeURIComponent).join('/')
    return `a:${encoded}`
  }
  return `${input.kind === 'folder' ? 'f' : 'n'}:${input.id}`
}

export type ParsedItemId =
  | { kind: 'folder'; id: string }
  | { kind: 'note'; id: string }
  | { kind: 'attachment'; path: string }
  | { kind: 'root' }

export function parseItemId(id: ItemId): ParsedItemId {
  if (id === ROOT_ID) return { kind: 'root' }
  const colon = id.indexOf(':')
  if (colon < 0) throw new Error(`Unknown tree item id: ${id}`)
  const prefix = id.slice(0, colon)
  const rest = id.slice(colon + 1)
  if (rest.length === 0) throw new Error(`Unknown tree item id: ${id}`)
  if (prefix === 'f') return { kind: 'folder', id: rest }
  if (prefix === 'n') return { kind: 'note', id: rest }
  if (prefix === 'a') {
    const path = rest.split('/').map(decodeURIComponent).join('/')
    return { kind: 'attachment', path }
  }
  throw new Error(`Unknown tree item id: ${id}`)
}
```

- [ ] **Step 4: Run tests**

Run: `bun test frontend/src/viewer/tree/types.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/viewer/tree/types.ts frontend/src/viewer/tree/types.test.ts
git commit -m "feat(tree): attachment TreeItem variant + a: id codec"
```

---

## Task 5: Frontend — `useAttachments` query

**Files:**
- Modify: `frontend/src/api/queries.ts`
- Test: `frontend/src/api/queries.test.tsx`

- [ ] **Step 1: Write the failing test**

Add to `frontend/src/api/queries.test.tsx` (reuse its existing QueryClient + `api` mock pattern — match how `useFolders`/`useFolderNotes` are tested in that file):

```tsx
import { useAttachments } from './queries'

it('useAttachments fetches /attachments and returns the array', async () => {
  vi.spyOn(api, 'get').mockResolvedValueOnce({
    attachments: [
      { path: 'a.png', mime_type: 'image/png', size_bytes: 10, mtime: 1, updated_at: '2026-06-10T00:00:00Z' },
    ],
  })
  const { result } = renderHook(() => useAttachments(), { wrapper })
  await waitFor(() => expect(result.current.data).toBeDefined())
  expect(api.get).toHaveBeenCalledWith('/attachments')
  expect(result.current.data?.[0].path).toBe('a.png')
})
```

(If this file uses `jest` rather than `vitest` globals, swap `vi` → `jest`. Mirror the exact wrapper/`renderHook` import already in the file.)

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test frontend/src/api/queries.test.tsx -t useAttachments`
Expected: FAIL — `useAttachments` is not exported.

- [ ] **Step 3: Implement**

Add to `frontend/src/api/queries.ts` (near `useFolders`):

```ts
export interface AttachmentSummary {
  path: string
  mime_type: string
  size_bytes: number
  mtime: number
  updated_at: string
}

const selectAttachments = (data: { attachments: AttachmentSummary[] }) => data.attachments

export function useAttachments() {
  const vaultId = useActiveVaultId()
  const demo = useDemoVaultOptional()
  const query = useQuery({
    queryKey: ['attachments', vaultId],
    queryFn: () => api.get<{ attachments: AttachmentSummary[] }>('/attachments'),
    select: selectAttachments,
    enabled: !demo?.active,
    staleTime: FOLDER_NOTES_STALE_MS,
  })
  // Demo vaults carry no binary attachments.
  if (demo?.active) {
    return { ...query, data: [] as AttachmentSummary[], isLoading: false, isFetching: false, error: null }
  }
  return query
}
```

- [ ] **Step 4: Run tests**

Run: `bun test frontend/src/api/queries.test.tsx -t useAttachments`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/api/queries.ts frontend/src/api/queries.test.tsx
git commit -m "feat(api): useAttachments query + AttachmentSummary"
```

---

## Task 6: Frontend — `synthesizeFolders` helper

**Files:**
- Create: `frontend/src/viewer/tree/synthesize-folders.ts`
- Test: `frontend/src/viewer/tree/synthesize-folders.test.ts`

The helper returns the real folders plus a synthetic folder row for every
attachment directory (and its ancestor chain) that isn't already a real folder.
Real folders always keep their id. Synthetic ids are `syn:<path>`.

- [ ] **Step 1: Write the failing test**

```ts
import { synthesizeFolders } from './synthesize-folders'
import type { Folder } from '../../api/queries'
import type { AttachmentSummary } from '../../api/queries'

const att = (path: string): AttachmentSummary => ({
  path, mime_type: 'image/png', size_bytes: 1, mtime: 0, updated_at: '',
})

describe('synthesizeFolders', () => {
  it('returns real folders unchanged when every attachment dir exists', () => {
    const real: Folder[] = [{ id: 'r1', parent_id: null, name: 'img', count: 2 }]
    const out = synthesizeFolders(real, [att('img/a.png')])
    expect(out).toHaveLength(1)
    expect(out[0]).toMatchObject({ id: 'r1', name: 'img' })
  })

  it('synthesizes a folder that exists only via an attachment', () => {
    const out = synthesizeFolders([], [att('pics/a.png')])
    const pics = out.find((f) => f.name === 'pics')
    expect(pics).toMatchObject({ id: 'syn:pics', parent_id: null, name: 'pics' })
  })

  it('synthesizes the full ancestor chain with correct parent ids', () => {
    const out = synthesizeFolders([], [att('a/b/c.png')])
    const a = out.find((f) => f.name === 'a')
    const b = out.find((f) => f.name === 'a/b')
    expect(a).toMatchObject({ id: 'syn:a', parent_id: null })
    expect(b).toMatchObject({ id: 'syn:a/b', parent_id: 'syn:a' })
  })

  it('links a synthetic child under an existing real parent', () => {
    const real: Folder[] = [{ id: 'r1', parent_id: null, name: 'docs', count: 0 }]
    const out = synthesizeFolders(real, [att('docs/sub/x.pdf')])
    const sub = out.find((f) => f.name === 'docs/sub')
    expect(sub).toMatchObject({ id: 'syn:docs/sub', parent_id: 'r1' })
  })

  it('root-level attachments add no folders', () => {
    const out = synthesizeFolders([], [att('cover.png')])
    expect(out).toHaveLength(0)
  })

  it('does not duplicate a synthetic dir shared by two attachments', () => {
    const out = synthesizeFolders([], [att('p/a.png'), att('p/b.png')])
    expect(out.filter((f) => f.name === 'p')).toHaveLength(1)
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test frontend/src/viewer/tree/synthesize-folders.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement**

```ts
import type { Folder } from '../../api/queries'
import type { AttachmentSummary } from '../../api/queries'

// Folder dirs that exist only because they hold attachments aren't returned by
// /api/folders (folders are derived from notes + markers). Synthesize them so
// every attachment is reachable. Real folders win their id; synthetic rows use
// `syn:<full-path>` ids and link to their parent (real or synthetic).
export function synthesizeFolders(
  real: Folder[],
  attachments: AttachmentSummary[],
): Folder[] {
  const byName = new Map<string, Folder>()
  for (const f of real) byName.set(f.name, f)

  // Collect every directory prefix from attachment paths.
  const dirs = new Set<string>()
  for (const a of attachments) {
    const slash = a.path.lastIndexOf('/')
    if (slash < 0) continue // root attachment, no folder
    const dir = a.path.slice(0, slash)
    const segments = dir.split('/')
    for (let i = 1; i <= segments.length; i++) dirs.add(segments.slice(0, i).join('/'))
  }

  // Synthesize missing dirs, shallow-first so parents exist before children.
  const sorted = [...dirs].sort((x, y) => x.split('/').length - y.split('/').length)
  for (const name of sorted) {
    if (byName.has(name)) continue
    const slash = name.lastIndexOf('/')
    const parentName = slash < 0 ? null : name.slice(0, slash)
    const parent = parentName == null ? null : byName.get(parentName) ?? null
    byName.set(name, {
      id: `syn:${name}`,
      parent_id: parent ? parent.id : null,
      name,
      count: 0,
    })
  }

  return [...byName.values()]
}
```

- [ ] **Step 4: Run tests**

Run: `bun test frontend/src/viewer/tree/synthesize-folders.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/viewer/tree/synthesize-folders.ts frontend/src/viewer/tree/synthesize-folders.test.ts
git commit -m "feat(tree): synthesizeFolders for attachment-only dirs"
```

---

## Task 7: Frontend — loader buckets attachments

**Files:**
- Modify: `frontend/src/viewer/tree/loader.ts`
- Test: `frontend/src/viewer/tree/loader.test.ts`

The loader gains an `attachments: AttachmentSummary[]` dep. `rootChildren`
appends root attachments (no slash); `folderChildren` appends attachments whose
dirname equals the folder's `name`. Each group is sorted by filename; attachments
render after notes within a folder.

- [ ] **Step 1: Write the failing test**

Add to `frontend/src/viewer/tree/loader.test.ts` (reuse its existing `buildLoader` + QueryClient setup; match how it seeds folder-notes cache):

```ts
import type { AttachmentSummary } from '../../api/queries'

const att = (path: string): AttachmentSummary => ({
  path, mime_type: path.endsWith('.pdf') ? 'application/pdf' : 'image/png',
  size_bytes: 1, mtime: 0, updated_at: '',
})

it('lists root attachments under ROOT', () => {
  const loader = buildLoader({
    folders: [], qc, vaultId: 'v1', sort: 'name-asc',
    attachments: [att('cover.png')],
  })
  const kids = loader.getChildren(ROOT_ID)
  const a = kids.find((k) => k.item.kind === 'attachment')
  expect(a?.item).toMatchObject({ kind: 'attachment', path: 'cover.png', mime: 'image/png' })
  expect(a?.itemId).toBe('a:cover.png')
})

it('buckets an attachment under its folder', () => {
  const folders = [{ id: 'f1', parent_id: null, name: 'img', count: 0 }]
  const loader = buildLoader({
    folders, qc, vaultId: 'v1', sort: 'name-asc',
    attachments: [att('img/a.png')],
  })
  // seed empty notes cache for the folder so notes resolve to []
  qc.setQueryData(['folder-notes-by-id', 'v1', 'f1'], [])
  const kids = loader.getChildren('f:f1')
  expect(kids.map((k) => k.item.kind)).toContain('attachment')
  const a = kids.find((k) => k.item.kind === 'attachment')
  expect(a?.item).toMatchObject({ path: 'img/a.png' })
})

it('does not leak a subfolder attachment into its parent', () => {
  const folders = [
    { id: 'f1', parent_id: null, name: 'img', count: 0 },
    { id: 'f2', parent_id: 'f1', name: 'img/sub', count: 0 },
  ]
  const loader = buildLoader({
    folders, qc, vaultId: 'v1', sort: 'name-asc',
    attachments: [att('img/sub/deep.png')],
  })
  qc.setQueryData(['folder-notes-by-id', 'v1', 'f1'], [])
  const kids = loader.getChildren('f:f1')
  expect(kids.find((k) => k.item.kind === 'attachment')).toBeUndefined()
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test frontend/src/viewer/tree/loader.test.ts`
Expected: FAIL — `buildLoader` doesn't accept/use `attachments`; no attachment items returned.

- [ ] **Step 3: Implement**

In `frontend/src/viewer/tree/loader.ts`:

1. Import the type and extend `LoaderDeps`:

```ts
import {
  FOLDER_NOTES_STALE_MS,
  ROOT_FOLDER_ID,
  type AttachmentSummary,
  type Folder,
  type NoteSummary,
} from '../../api/queries'
```

```ts
interface LoaderDeps {
  folders: Folder[]
  qc: QueryClient
  vaultId: string
  sort: SortKey
  attachments?: AttachmentSummary[]
  fetchFolderNotes?: (folderId: string) => Promise<NoteSummary[]>
  onChildrenLoaded?: (folderId: string) => void
}
```

2. Add helpers + bucket calls. Add near `noteToTreeItem`:

```ts
function attachmentDir(path: string): string {
  const slash = path.lastIndexOf('/')
  return slash < 0 ? '' : path.slice(0, slash)
}

function attachmentToTreeItem(a: AttachmentSummary): Extract<TreeItem, { kind: 'attachment' }> {
  return { kind: 'attachment', path: a.path, mime: a.mime_type, size: a.size_bytes }
}

function attachmentItemsForDir(deps: LoaderDeps, dir: string): LoaderItem[] {
  const list = (deps.attachments ?? []).filter((a) => attachmentDir(a.path) === dir)
  const sign = deps.sort.endsWith('-desc') ? -1 : 1
  const fname = (p: string) => p.split('/').pop() ?? p
  return list
    .sort((a, b) => sign * fname(a.path).localeCompare(fname(b.path)))
    .map((a) => ({
      itemId: formatItemId({ kind: 'attachment', path: a.path }),
      item: attachmentToTreeItem(a),
      isFolder: false,
    }))
}
```

3. Resolve a folder id → its path name, then append attachment items. Update
`folderChildren` and `rootChildren`:

```ts
function rootChildren(deps: LoaderDeps): LoaderItem[] {
  const tops = folderLoaderItems(deps, null)
  const noteItems = noteChildItems(deps, ROOT_FOLDER_ID) ?? []
  const attItems = attachmentItemsForDir(deps, '')
  return [...tops, ...noteItems, ...attItems]
}

function folderChildren(deps: LoaderDeps, folderId: string): LoaderItem[] {
  const childFolders = folderLoaderItems(deps, folderId)
  const noteItems = noteChildItems(deps, folderId)
  const folder = deps.folders.find((f) => f.id === folderId)
  const attItems = folder ? attachmentItemsForDir(deps, folder.name) : []
  const notes = noteItems ?? []
  return [...childFolders, ...notes, ...attItems]
}
```

(Note: `folderChildren` previously returned `childFolders` alone on a notes
cache miss; now it always appends loaded attachments so they show immediately
while notes lazy-load.)

- [ ] **Step 4: Run tests**

Run: `bun test frontend/src/viewer/tree/loader.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/viewer/tree/loader.ts frontend/src/viewer/tree/loader.test.ts
git commit -m "feat(tree): loader buckets attachments into folders + root"
```

---

## Task 8: Frontend — thread attachments through `useEngramTree`

**Files:**
- Modify: `frontend/src/viewer/tree/use-engram-tree.ts`

No new test (covered by loader tests + the integration in Task 12); this wires
the dep and makes the tree rebuild when attachments land.

- [ ] **Step 1: Add `attachments` to `Deps` + pass to loader**

In `frontend/src/viewer/tree/use-engram-tree.ts`:

```ts
import type { AttachmentSummary, Folder, NoteSummary } from '../../api/queries'
```

Add to the `Deps` interface (next to `folders`):

```ts
  attachments?: AttachmentSummary[]
```

Pass it into `buildLoader`:

```ts
    () => buildLoader({
      folders: deps.folders,
      qc: deps.qc,
      vaultId: deps.vaultId,
      sort: deps.sort,
      attachments: deps.attachments,
      fetchFolderNotes: deps.fetchFolderNotes,
      onChildrenLoaded: (folderId) => {
        // ...unchanged...
      },
    }),
    [deps.folders, deps.qc, deps.vaultId, deps.sort, deps.attachments, deps.fetchFolderNotes],
```

- [ ] **Step 2: Fold an attachments fingerprint into the structure key**

Find `const structureKey = treeStructureKey(deps.folders, deps.sort)` and the
`treeStructureKey` helper. Add an attachments fingerprint so HT rebuilds when the
attachment set changes within already-known folders:

```ts
function attachmentsFingerprint(attachments?: AttachmentSummary[]): string {
  if (!attachments || attachments.length === 0) return '0'
  // length + max(updated_at) is enough: the list is static per fetch, and any
  // add/remove changes one of the two.
  let max = ''
  for (const a of attachments) if (a.updated_at > max) max = a.updated_at
  return `${attachments.length}:${max}`
}
```

Then:

```ts
  const structureKey =
    treeStructureKey(deps.folders, deps.sort) + '#' + attachmentsFingerprint(deps.attachments)
```

- [ ] **Step 3: Verify the tree still builds**

Run: `bun test frontend/src/viewer/folder-tree.test.tsx`
Expected: PASS (existing tests unaffected — `attachments` is optional).

- [ ] **Step 4: Commit**

```bash
git add frontend/src/viewer/tree/use-engram-tree.ts
git commit -m "feat(tree): thread attachments into loader + structure key"
```

---

## Task 9: Frontend — attachment row in `tree-row.tsx`

**Files:**
- Modify: `frontend/src/viewer/tree/tree-row.tsx`
- Test: `frontend/src/viewer/tree/tree-row.test.tsx`

Attachment rows are pure navigation `<Link>`s — no context menu, no long-press,
no drag (those belong to Phase 2). They get a mime-based leading icon + an
uppercase extension badge.

- [ ] **Step 1: Write the failing test**

Add to `frontend/src/viewer/tree/tree-row.test.tsx` (reuse its existing render
harness that builds an `ItemInstance` mock; match how note rows are tested there):

```tsx
it('renders an attachment row as a link to /attachment/<path> with an ext badge', () => {
  const instance = makeInstance({
    item: { kind: 'attachment', path: 'img/a.png', mime: 'image/png', size: 10 },
  })
  render(<MemoryRouter><TreeRow instance={instance} /></MemoryRouter>)
  const link = screen.getByRole('link')
  expect(link).toHaveAttribute('href', '/attachment/img/a.png')
  expect(screen.getByText('a.png')).toBeInTheDocument()
  expect(screen.getByText('PNG')).toBeInTheDocument()
})
```

(Use the file's existing `makeInstance`/render helpers verbatim — only the
`item` payload is new. If the helper is named differently, match it.)

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test frontend/src/viewer/tree/tree-row.test.tsx -t attachment`
Expected: FAIL — attachment item renders as a note (wrong href `/note/undefined`) or throws.

- [ ] **Step 3: Implement**

In `frontend/src/viewer/tree/tree-row.tsx`:

1. Extend the lucide import:

```tsx
import { ChevronRight, File, FileText, Image } from 'lucide-react'
```

2. Add an attachment branch **after** the folder branch and **before** the note
return. Build the link target from the path:

```tsx
  if (item.kind === 'attachment') {
    const filename = item.path.split('/').pop() ?? item.path
    const dot = filename.lastIndexOf('.')
    const ext = dot > 0 ? filename.slice(dot + 1).toLowerCase() : null
    const encoded = item.path.split('/').map(encodeURIComponent).join('/')
    const Icon = item.mime.startsWith('image/')
      ? Image
      : item.mime === 'application/pdf'
        ? FileText
        : File
    return (
      <Link
        to={`/attachment/${encoded}`}
        {...instance.getProps()}
        onContextMenu={contextMenuHandler}
        aria-selected={instance.isSelected()}
        className={rowClass(instance)}
        style={{ paddingLeft: `${notePad}px` }}
      >
        <IndentGuides depth={depth} />
        <Icon aria-hidden="true" className="h-3.5 w-3.5 shrink-0 text-gray-400 dark:text-gray-500" />
        <span className="min-w-0 flex-1 truncate">{filename}</span>
        {ext && (
          <span className="shrink-0 text-xs uppercase text-gray-400 dark:text-gray-500">{ext}</span>
        )}
      </Link>
    )
  }
```

3. The rename branch at the top references `item.kind === 'folder' ? ... : ...`
for padding and `leafName`. `leafName` already handles non-folder items via
`item.path.split('/').pop()`, which covers attachments — no change needed (and
attachments never enter renaming in Phase 1).

- [ ] **Step 4: Run tests**

Run: `bun test frontend/src/viewer/tree/tree-row.test.tsx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/viewer/tree/tree-row.tsx frontend/src/viewer/tree/tree-row.test.tsx
git commit -m "feat(tree): render attachment rows with icon + link"
```

---

## Task 10: Frontend — fix `AttachmentImg` to fetch raw bytes

**Files:**
- Modify: `frontend/src/viewer/attachment-img.tsx`
- Create: `frontend/src/viewer/attachment-img.test.tsx`

`AttachmentImg` currently fetches the JSON endpoint via `getBlob`, so the image
never renders. Append `?raw=1` so it streams real bytes (Task 3).

- [ ] **Step 1: Write the failing test**

```tsx
import { render, screen, waitFor } from '@testing-library/react'
import { vi } from 'vitest'
import AttachmentImg from './attachment-img'
import { api } from '../api/client'

beforeAll(() => {
  // jsdom lacks createObjectURL
  // @ts-expect-error test shim
  URL.createObjectURL = vi.fn(() => 'blob:fake')
  // @ts-expect-error test shim
  URL.revokeObjectURL = vi.fn()
})

it('fetches the attachment with ?raw=1 and renders an img', async () => {
  const spy = vi.spyOn(api, 'getBlob').mockResolvedValueOnce(new Blob(['x'], { type: 'image/png' }))
  render(<AttachmentImg path="img/a.png" alt="A" />)
  await waitFor(() => expect(screen.getByRole('img')).toBeInTheDocument())
  expect(spy).toHaveBeenCalledWith('/attachments/img/a.png?raw=1')
})
```

(Swap `vitest` → `jest` globals if the project uses jest; match a sibling test's import header.)

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test frontend/src/viewer/attachment-img.test.tsx`
Expected: FAIL — `getBlob` called with `/attachments/img/a.png` (no `?raw=1`).

- [ ] **Step 3: Implement**

In `frontend/src/viewer/attachment-img.tsx`, change the fetch line:

```tsx
    const encoded = path.split('/').map(encodeURIComponent).join('/')
    api
      .getBlob(`/attachments/${encoded}?raw=1`)
```

- [ ] **Step 4: Run tests**

Run: `bun test frontend/src/viewer/attachment-img.test.tsx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/viewer/attachment-img.tsx frontend/src/viewer/attachment-img.test.tsx
git commit -m "fix(viewer): AttachmentImg fetches raw bytes via ?raw=1"
```

---

## Task 11: Frontend — `AttachmentPage` preview + route

**Files:**
- Create: `frontend/src/viewer/attachment-page.tsx`
- Modify: `frontend/src/router.tsx`
- Test: `frontend/src/viewer/attachment-page.test.tsx`

- [ ] **Step 1: Write the failing test**

```tsx
import { render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter, Routes, Route } from 'react-router'
import { vi } from 'vitest'
import AttachmentPage from './attachment-page'
import { api } from '../api/client'

beforeAll(() => {
  // @ts-expect-error shim
  URL.createObjectURL = vi.fn(() => 'blob:fake')
  // @ts-expect-error shim
  URL.revokeObjectURL = vi.fn()
})

function renderAt(path: string) {
  return render(
    <MemoryRouter initialEntries={[`/attachment/${path}`]}>
      <Routes>
        <Route path="/attachment/*" element={<AttachmentPage />} />
      </Routes>
    </MemoryRouter>,
  )
}

it('renders an <img> for an image attachment', async () => {
  vi.spyOn(api, 'getBlob').mockResolvedValueOnce(new Blob(['x'], { type: 'image/png' }))
  renderAt('img/a.png')
  await waitFor(() => expect(screen.getByRole('img')).toBeInTheDocument())
  expect(api.getBlob).toHaveBeenCalledWith('/attachments/img/a.png?raw=1')
})

it('renders an iframe for a pdf attachment', async () => {
  vi.spyOn(api, 'getBlob').mockResolvedValueOnce(new Blob(['x'], { type: 'application/pdf' }))
  renderAt('doc.pdf')
  await waitFor(() => expect(screen.getByTitle('doc.pdf')).toBeInTheDocument())
})

it('renders a download fallback for unsupported types', async () => {
  vi.spyOn(api, 'getBlob').mockResolvedValueOnce(new Blob(['x'], { type: 'application/zip' }))
  renderAt('a.zip')
  await waitFor(() => expect(screen.getByRole('link', { name: /download/i })).toBeInTheDocument())
})

it('shows an error state when the fetch fails', async () => {
  vi.spyOn(api, 'getBlob').mockRejectedValueOnce(new Error('boom'))
  renderAt('missing.png')
  await waitFor(() => expect(screen.getByText(/couldn.t load/i)).toBeInTheDocument())
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test frontend/src/viewer/attachment-page.test.tsx`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement**

Create `frontend/src/viewer/attachment-page.tsx`:

```tsx
import { useEffect, useState } from 'react'
import { useParams } from 'react-router'
import { api } from '../api/client'

// Read-only preview for a single attachment. The path is the route splat
// (`/attachment/*`). Fetches raw bytes (?raw=1) as a typed Blob so the browser
// renders images / PDFs natively; unsupported types fall back to a download link.
export default function AttachmentPage() {
  const params = useParams()
  const path = params['*'] ?? ''
  const filename = path.split('/').pop() ?? path

  const [url, setUrl] = useState<string | null>(null)
  const [mime, setMime] = useState<string>('')
  const [error, setError] = useState(false)

  useEffect(() => {
    let revoke: string | null = null
    let cancelled = false
    setUrl(null)
    setError(false)
    const encoded = path.split('/').map(encodeURIComponent).join('/')
    api
      .getBlob(`/attachments/${encoded}?raw=1`)
      .then((blob) => {
        if (cancelled) return
        const objectUrl = URL.createObjectURL(blob)
        revoke = objectUrl
        setMime(blob.type)
        setUrl(objectUrl)
      })
      .catch(() => !cancelled && setError(true))
    return () => {
      cancelled = true
      if (revoke) URL.revokeObjectURL(revoke)
    }
  }, [path])

  if (error) {
    return (
      <section className="p-6">
        <p className="text-sm text-destructive">Couldn't load {filename}.</p>
      </section>
    )
  }
  if (!url) {
    return (
      <section className="p-6">
        <p className="text-sm text-muted-foreground">Loading {filename}…</p>
      </section>
    )
  }
  if (mime.startsWith('image/')) {
    return (
      <section className="flex h-full items-center justify-center overflow-auto p-6">
        <img src={url} alt={filename} className="max-h-full max-w-full rounded" />
      </section>
    )
  }
  if (mime === 'application/pdf') {
    return <iframe title={filename} src={url} className="h-full w-full border-0" />
  }
  return (
    <section className="p-6">
      <p className="mb-3 text-sm text-muted-foreground">Preview not supported for {filename}.</p>
      <a
        href={url}
        download={filename}
        className="inline-flex items-center rounded bg-primary px-3 py-2 text-sm text-primary-foreground"
      >
        Download {filename}
      </a>
    </section>
  )
}
```

In `frontend/src/router.tsx`:

1. Add the lazy import near the other viewer lazies:

```tsx
const AttachmentPage = lazy(() => import('./viewer/attachment-page'))
```

2. Add the route next to `/note/:id` inside the `AppLayout` children:

```tsx
                    { path: '/note/:id', element: suspended(<NotePage />) },
                    { path: '/attachment/*', element: suspended(<AttachmentPage />) },
```

- [ ] **Step 4: Run tests**

Run: `bun test frontend/src/viewer/attachment-page.test.tsx`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/viewer/attachment-page.tsx frontend/src/router.tsx frontend/src/viewer/attachment-page.test.tsx
git commit -m "feat(viewer): AttachmentPage preview + /attachment/* route"
```

---

## Task 12: Frontend — wire attachments into `FolderTree`

**Files:**
- Modify: `frontend/src/viewer/folder-tree.tsx`
- Test: `frontend/src/viewer/folder-tree.test.tsx`

- [ ] **Step 1: Write the failing test**

Add to `frontend/src/viewer/folder-tree.test.tsx` (match its existing mock setup
for `useFolders`/`useFolderNotesById`; add a `useAttachments` mock):

```tsx
it('renders an attachment row from useAttachments', async () => {
  mockUseFolders([])              // however the file stubs folders
  mockUseAttachments([
    { path: 'cover.png', mime_type: 'image/png', size_bytes: 1, mtime: 0, updated_at: '2026-06-10T00:00:00Z' },
  ])
  render(<FolderTree />, { wrapper })
  expect(await screen.findByText('cover.png')).toBeInTheDocument()
})
```

(Implement `mockUseAttachments` the same way the file already mocks `useFolders`
— a `vi.mock('../api/queries', ...)` factory returning the stubbed hook. If the
file mocks the whole module, add `useAttachments` to that factory.)

- [ ] **Step 2: Run test to verify it fails**

Run: `bun test frontend/src/viewer/folder-tree.test.tsx -t attachment`
Expected: FAIL — no attachment row (FolderTree doesn't read attachments yet).

- [ ] **Step 3: Implement**

In `frontend/src/viewer/folder-tree.tsx`:

1. Import the hook + helper + `useMemo`:

```tsx
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
```

```tsx
import {
  // ...existing imports...
  useAttachments,
  type AttachmentSummary,
} from '../api/queries'
import { synthesizeFolders } from './tree/synthesize-folders'
```

2. Read attachments + build the synthesized folder list. After the
`useFolders()` line:

```tsx
  const { data: attachments = [] as AttachmentSummary[] } = useAttachments()
```

3. Add a stable empty array sentinel near `EMPTY_FOLDERS`:

```tsx
const EMPTY_ATTACHMENTS: AttachmentSummary[] = []
```

4. Compute the augmented folders (memoized so identity is stable):

```tsx
  const allFolders = useMemo(
    () => synthesizeFolders(folders ?? EMPTY_FOLDERS, attachments ?? EMPTY_ATTACHMENTS),
    [folders, attachments],
  )
```

5. Pass `allFolders` + `attachments` to `useEngramTree`:

```tsx
  const { tree, virtualizer, items } = useEngramTree({
    folders: allFolders,
    attachments: attachments ?? EMPTY_ATTACHMENTS,
    qc,
    vaultId: vaultId ?? '',
    sort,
    scrollParentRef: scrollRef,
    onRenameCommit,
    onMove,
    fetchFolderNotes,
  })
```

6. Guard `onMove` so an attachment row (or any non-folder/root target) is never a
drop destination. Change the early guard:

```tsx
  const onMove = (sourceIds: string[], targetItemId: string) => {
    const target = parseItemId(targetItemId)
    if (target.kind !== 'folder' && target.kind !== 'root') return
    // ...rest unchanged...
```

7. Update the empty-state guard so a vault with only attachments still renders.
Change:

```tsx
  if (!folders || (folders.length === 0 && rootNotes.length === 0)) {
```

to:

```tsx
  if (!folders || (allFolders.length === 0 && rootNotes.length === 0 && attachments.length === 0)) {
```

(`allFolders` already includes synthesized dirs, so an images-only subtree
renders; a vault with only root-level attachments also passes via the
`attachments.length` clause.)

- [ ] **Step 4: Run tests**

Run: `bun test frontend/src/viewer/folder-tree.test.tsx`
Expected: PASS (new test + existing tests green).

- [ ] **Step 5: Commit**

```bash
git add frontend/src/viewer/folder-tree.tsx frontend/src/viewer/folder-tree.test.tsx
git commit -m "feat(tree): wire attachments + synthesized folders into FolderTree"
```

---

## Task 13: Full verification + lints

- [ ] **Step 1: Backend suite**

Run: `mix test`
Expected: PASS.

- [ ] **Step 2: Frontend suite**

Run: `cd frontend && bun test`
Expected: PASS.

- [ ] **Step 3: Frontend build + lints (per project rules)**

Run: `cd frontend && bun run build && bun run lint:obsidian && bun run lint:css && bunx biome check .`
Expected: clean.

- [ ] **Step 4: Manual smoke (optional, via local browser CDP tunnel)**

Bring up `make saas-dev`, open the app, confirm: image + PDF + a non-previewable
file appear in the tree under the right folders (incl. an images-only folder),
clicking each opens the expected preview, and the sidebar stays mounted.

- [ ] **Step 5: Commit any lint fixups, then open the PR** (after user review per workflow rules).

---

## Spec coverage check

- Backend `GET /api/attachments` → Task 1 (context) + Task 2 (endpoint/route).
- Raw bytes / fix broken `AttachmentImg` → Task 3 (backend `?raw=1`) + Task 10 (frontend).
- `attachment` TreeItem + `a:` id → Task 4.
- `useAttachments` query → Task 5.
- Synthesize attachment-only folders → Task 6 + wired in Task 12.
- Loader bucketing → Task 7 + Task 8 (rebuild trigger).
- Tree row icon/badge/link → Task 9.
- `/attachment/*` preview (image/pdf/unsupported/loading/error) → Task 11.
- FolderTree integration + empty-state + drop-target guard → Task 12.
- Verification + lints → Task 13.

## Deferred (Phase 2/3, out of scope)

- Delete / rename / move / drag for attachments (the row deliberately wires no
  context menu, long-press, or drag in Phase 1).
- Upload + paid-tier upload gating in the web UI.
- True interleave-sort of notes + attachments (Phase 1 lists attachments after
  notes within a folder, each group sorted by name).
- Thumbnails in tree rows; attachment-list pagination for very large vaults.
