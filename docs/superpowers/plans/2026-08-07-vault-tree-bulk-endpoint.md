# Vault Tree Bulk Endpoint Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the web tree's per-folder request fan-out (20–33 calls, ~5.6s of HTTP/1.1 queueing) with a single `GET /api/vault/tree` call.

**Architecture:** A new read-only Phoenix controller returns every folder, note, and attachment the tree renders, in one payload, with a `since_seq` short-circuit. The React client calls it once on vault load and seeds the *existing* TanStack cache keys (`folders`, `attachments`, `folder-notes-by-id`) via `setQueryData`, so every existing consumer keeps working untouched and the per-folder prefetch loop is deleted.

**Tech Stack:** Elixir/Phoenix 1.8, Ecto, OpenApiSpex, ExUnit; React 19, TanStack Query v5, Vitest.

## Global Constraints

- **Additive only.** `/api/folders`, `/api/folders/list`, `/api/folders/by-id/:id/notes` stay exactly as they are — the plugin and public API depend on them.
- **OpenAPI is CI-gated.** `.github/workflows/verify.yml` regenerates the spec and diffs it against the committed `openapi.json`. A new route without an `operation(...)` block, a response schema, and a regenerated `openapi.json` **fails CI**.
- **Paths are encrypted at rest.** Every path read decrypts `path_ciphertext`/`path_nonce` with the user DEK and AAD binding. Never bypass `path_aad/3`.
- **Tenant isolation.** All queries run inside `Repo.with_tenant(user.id, fn -> ... end)`.
- **No version bumps** in feature work — release-please owns `mix.exs`.
- Backend gate before push, run **sequentially**: `mix format`, `mix credo`, `mix dialyzer`, then full `mix test --warnings-as-errors`.
- Frontend gate: `bunx tsc --noEmit`, `./node_modules/.bin/biome ci .`, `bunx vitest run`.

## Deviations from the approved spec

Two changes I'd make, both discovered while reading the code. **Confirm before Task 1.**

1. **Folder objects use `name`, not `path`.** The spec wrote `{id, path, parent_id, count}`. The existing `GET /api/folders` and the frontend `Folder` interface (`frontend/src/api/queries.ts:303`) both use `name` — which already *is* the full path. Matching the existing shape means the client can seed the `folders` cache directly with zero mapping.

2. **The client seeds `folders` and `attachments` caches too, not just notes.** The spec flagged "attachment double-source" as a risk. Seeding all three caches from the one response resolves it: `useFolders`/`useAttachments` become cache reads instead of separate fetches, so there is exactly one source of truth and no consumer changes. This is what makes it a true single call (35 → 1) rather than 35 → 3.

## File Structure

| File | Responsibility |
|---|---|
| `lib/engram/crypto/path_crypto.ex` (create) | Shared AAD-bound path decrypt. Extracted so two controllers can't drift on AAD binding. |
| `lib/engram_web/controllers/vault_tree_controller.ex` (create) | The one read: folders + notes + attachments + `change_seq`. |
| `lib/engram_web/schemas/vault_tree.ex` (create) | OpenApiSpex response schema. |
| `lib/engram_web/router.ex` (modify) | One route in the vault-scoped pipeline. |
| `openapi.json` (regenerate) | CI-gated spec snapshot. |
| `frontend/src/api/queries.ts` (modify) | `useVaultTree` + cache seeding. |
| `frontend/src/viewer/folder-tree.tsx` (modify) | Delete the prefetch loop. |

---

### Task 1: Extract the path-decrypt helpers

`SyncController` holds `path_aad/3` and `decrypt_path!/4` as private functions. The new controller needs identical behavior. Copying them risks the two drifting on AAD binding — a security-relevant bug. Move them to a shared module first, as a pure refactor with no behavior change.

**Files:**
- Create: `lib/engram/crypto/path_crypto.ex`
- Modify: `lib/engram_web/controllers/sync_controller.ex`
- Test: `test/engram_web/controllers/sync_controller_test.exs` (existing, must stay green)

**Interfaces:**
- Consumes: `Engram.Crypto.aad_for_row/3`, `Engram.Crypto.Envelope.decrypt/4`
- Produces: `Engram.Crypto.PathCrypto.aad(table :: atom, id :: binary, dek_version :: integer) :: binary` and `Engram.Crypto.PathCrypto.decrypt!(ciphertext :: binary, nonce :: binary, dek :: binary, aad :: binary) :: binary`

- [ ] **Step 1: Create the module**

```elixir
defmodule Engram.Crypto.PathCrypto do
  @moduledoc """
  AAD-bound path decryption, shared by every controller that renders
  cleartext paths from `path_ciphertext`.

  Extracted from SyncController so the manifest and the vault-tree read
  cannot drift on AAD binding: rows with `dek_version >= 2` bind to
  "notes:path:<id>" / "attachments:path:<id>", and legacy v1 rows decrypt
  with empty AAD. Getting that wrong on one caller and not the other is a
  silent decrypt failure at best.
  """

  alias Engram.Crypto
  alias Engram.Crypto.Envelope

  @spec aad(atom(), binary(), integer() | nil) :: binary()
  def aad(table, id, dek_version) when is_integer(dek_version) and dek_version >= 2,
    do: Crypto.aad_for_row(table, :path, id)

  def aad(_table, _id, _v), do: <<>>

  @spec decrypt!(binary(), binary(), binary(), binary()) :: binary()
  def decrypt!(ciphertext, nonce, dek, aad) do
    case Envelope.decrypt(ciphertext, nonce, dek, aad) do
      {:ok, path} -> path
      :error -> raise "path decrypt failed — possible data corruption"
    end
  end
end
```

- [ ] **Step 2: Point SyncController at it**

In `lib/engram_web/controllers/sync_controller.ex`, add `alias Engram.Crypto.PathCrypto` to the alias block, delete the private `path_aad/3` and `decrypt_path!/4` definitions, and replace their call sites:

- `path_aad(:notes, id, dek_version)` → `PathCrypto.aad(:notes, id, dek_version)`
- `path_aad(:attachments, id, dek_version)` → `PathCrypto.aad(:attachments, id, dek_version)`
- `decrypt_path!(path_ct, path_nonce, dek, aad)` → `PathCrypto.decrypt!(path_ct, path_nonce, dek, aad)`

- [ ] **Step 3: Verify no behavior changed**

Run: `mix test test/engram_web/controllers/sync_controller_test.exs`
Expected: PASS, same count as before the refactor. This is a pure move — any failure means the extraction changed behavior.

- [ ] **Step 4: Commit**

```bash
git add lib/engram/crypto/path_crypto.ex lib/engram_web/controllers/sync_controller.ex
git commit -m "refactor(crypto): extract shared AAD-bound path decrypt"
```

---

### Task 2: The endpoint — notes, with the since_seq short-circuit

**Files:**
- Create: `lib/engram_web/controllers/vault_tree_controller.ex`
- Modify: `lib/engram_web/router.ex`
- Test: `test/engram_web/controllers/vault_tree_controller_test.exs`

**Interfaces:**
- Consumes: `Engram.Crypto.PathCrypto.aad/3`, `Engram.Crypto.PathCrypto.decrypt!/4`, `Engram.Vaults.current_seq/2`, `Engram.Crypto.get_dek/1`
- Produces: `GET /api/vault/tree` returning `%{folders: [...], notes: [...], attachments: [...], change_seq: integer}` or `%{unchanged: true, change_seq: integer}`

- [ ] **Step 1: Write the failing test**

Create `test/engram_web/controllers/vault_tree_controller_test.exs`:

```elixir
defmodule EngramWeb.VaultTreeControllerTest do
  use EngramWeb.ConnCase, async: true

  setup %{conn: conn} do
    user = insert(:user)
    insert(:subscription, user: user, tier: "pro", status: "active")
    vault = insert(:vault, user: user, is_default: true)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    grant_api_write!(user)
    authed = put_req_header(conn, "authorization", "Bearer #{api_key}")
    %{conn: authed, user: user, vault: vault}
  end

  describe "GET /vault/tree" do
    test "returns an empty tree for a new user", %{conn: conn} do
      body = conn |> get("/api/vault/tree") |> json_response(200)

      assert body["notes"] == []
      assert body["folders"] == []
      assert body["attachments"] == []
      assert body["change_seq"] == 0
    end

    test "returns every note with id, path and both timestamps", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Test/A.md", content: "# Alpha", mtime: 1_000.0})
      post(conn, "/api/notes", %{path: "Test/B.md", content: "# Beta", mtime: 1_000.0})

      body = conn |> get("/api/vault/tree") |> json_response(200)

      assert length(body["notes"]) == 2
      note = Enum.find(body["notes"], &(&1["path"] == "Test/A.md"))
      assert note["id"]
      assert note["created_at"]
      assert note["updated_at"]
    end

    test "omits the fields the tree never reads", %{conn: conn} do
      post(conn, "/api/notes", %{path: "A.md", content: "# A", mtime: 1_000.0})

      body = conn |> get("/api/vault/tree") |> json_response(200)
      note = hd(body["notes"])

      # These are the ~128 bytes/note that disqualified reusing the manifest.
      refute Map.has_key?(note, "content_hash")
      refute Map.has_key?(note, "crdt_head")
      refute Map.has_key?(note, "tags")
    end

    test "since_seq matching the current seq short-circuits", %{conn: conn} do
      post(conn, "/api/notes", %{path: "A.md", content: "# A", mtime: 1_000.0})
      seq = conn |> get("/api/vault/tree") |> json_response(200) |> Map.fetch!("change_seq")

      body = conn |> get("/api/vault/tree?since_seq=#{seq}") |> json_response(200)

      assert body["unchanged"] == true
      assert body["change_seq"] == seq
      refute Map.has_key?(body, "notes")
    end

    test "a stale or garbage since_seq returns the full payload", %{conn: conn} do
      post(conn, "/api/notes", %{path: "A.md", content: "# A", mtime: 1_000.0})

      for raw <- ["0", "not-a-number", "-5", ""] do
        body = conn |> get("/api/vault/tree?since_seq=#{raw}") |> json_response(200)
        refute body["unchanged"]
        assert length(body["notes"]) == 1
      end
    end

    test "never leaks another user's notes", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Mine.md", content: "# Mine", mtime: 1_000.0})

      other = insert(:user)
      insert(:subscription, user: other, tier: "pro", status: "active")
      other_vault = insert(:vault, user: other, is_default: true)
      {:ok, other_key, _} = Engram.Accounts.create_api_key(other, "other-key")
      grant_api_write!(other)

      other_conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{other_key}")

      post(other_conn, "/api/notes", %{path: "Theirs.md", content: "# T", mtime: 1_000.0})

      body = conn |> get("/api/vault/tree") |> json_response(200)
      paths = Enum.map(body["notes"], & &1["path"])

      assert "Mine.md" in paths
      refute "Theirs.md" in paths
      assert other_vault.id
    end
  end
end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `mix test test/engram_web/controllers/vault_tree_controller_test.exs`
Expected: FAIL — no route matches `/api/vault/tree` (`Phoenix.Router.NoRouteError`).

- [ ] **Step 3: Create the controller**

Create `lib/engram_web/controllers/vault_tree_controller.ex`:

```elixir
defmodule EngramWeb.VaultTreeController do
  @moduledoc """
  One read for the web file tree.

  The tree needs every folder, note and attachment in the vault at once.
  `/api/folders/list?folder=` was built for the plugin, which walks one
  folder at a time, so the SPA was firing one request per folder — 20-33
  requests moving 39.5 KB, serialized 6-at-a-time by the HTTP/1.1
  connection limit, up to 5.6s of pure queueing before the last one was
  even sent. This is that same data in one response.

  Payload is deliberately minimal: `noteToTreeItem` derives title and
  extension from `path`, so `title`, `tags`, `version`, `mtime`,
  `content_hash` and `crdt_head` are all omitted. Reusing the sync
  manifest was rejected for exactly that reason — it carries ~128 bytes
  per note of hashes the tree never reads (~1.3 MB at 10k notes).
  """
  use EngramWeb, :controller

  import Ecto.Query

  alias Engram.Attachments.Attachment
  alias Engram.Crypto
  alias Engram.Crypto.PathCrypto
  alias Engram.Notes
  alias Engram.Notes.Note
  alias Engram.Repo

  def show(conn, params) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault
    current = Engram.Vaults.current_seq(user.id, vault.id)

    if parse_since_seq(params["since_seq"]) == current do
      json(conn, %{unchanged: true, change_seq: current})
    else
      case Crypto.get_dek(user) do
        {:ok, dek} -> render_tree(conn, user, vault, dek, current)
        {:error, :no_dek} -> json(conn, empty_tree(current))
      end
    end
  end

  defp empty_tree(current_seq) do
    %{folders: [], notes: [], attachments: [], change_seq: current_seq}
  end

  defp render_tree(conn, user, vault, dek, current_seq) do
    {:ok, note_rows} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(
          from(n in Note,
            where:
              n.user_id == ^user.id and n.vault_id == ^vault.id and is_nil(n.deleted_at) and
                n.kind == "note",
            select:
              {n.id, n.dek_version, n.path_ciphertext, n.path_nonce, n.inserted_at, n.updated_at}
          )
        )
      end)

    {:ok, attachment_rows} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(
          from(a in Attachment,
            where: a.user_id == ^user.id and a.vault_id == ^vault.id and is_nil(a.deleted_at),
            select:
              {a.id, a.dek_version, a.path_ciphertext, a.path_nonce, a.mime_type, a.size_bytes}
          )
        )
      end)

    # Sequential on purpose — SyncController measured path-sized decrypts at
    # ~4µs each (10k in ~43ms) and found chunked parallel SLOWER, because
    # copying results back to the caller's heap rivals the AES-GCM work.
    notes =
      Crypto.measure_decrypt_batch(:vault_tree_notes, length(note_rows), fn ->
        Enum.map(note_rows, fn {id, dek_version, path_ct, path_nonce, created, updated} ->
          aad = PathCrypto.aad(:notes, id, dek_version)

          %{
            id: id,
            path: PathCrypto.decrypt!(path_ct, path_nonce, dek, aad),
            created_at: created,
            updated_at: updated
          }
        end)
      end)
      |> Enum.sort_by(& &1.path)

    attachments =
      Crypto.measure_decrypt_batch(:vault_tree_attachments, length(attachment_rows), fn ->
        Enum.map(attachment_rows, fn {id, dek_version, path_ct, path_nonce, mime, size} ->
          aad = PathCrypto.aad(:attachments, id, dek_version)

          %{
            id: id,
            path: PathCrypto.decrypt!(path_ct, path_nonce, dek, aad),
            mime_type: mime,
            size_bytes: size
          }
        end)
      end)
      |> Enum.sort_by(& &1.path)

    json(conn, %{
      folders: folders_payload(user, vault),
      notes: notes,
      attachments: attachments,
      change_seq: current_seq
    })
  end

  # Same shape FoldersController.index/2 returns — `name` IS the full path.
  # Matching it exactly lets the client seed the existing `folders` cache
  # with no mapping layer.
  defp folders_payload(user, vault) do
    {:ok, folders} = Notes.list_folders_with_counts(user, vault)
    markers = Notes.list_folder_markers(user, vault)
    id_by_path = Map.new(markers, fn m -> {m.folder, m.id} end)

    Enum.map(folders, fn f ->
      %{
        id: Map.get(id_by_path, f.folder),
        name: f.folder,
        count: f.count,
        parent_id: Map.get(id_by_path, parent_path(f.folder))
      }
    end)
  end

  defp parent_path(path) do
    case :binary.matches(path, "/") do
      [] -> ""
      matches -> {pos, _} = List.last(matches); binary_part(path, 0, pos)
    end
  end

  defp parse_since_seq(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp parse_since_seq(_), do: nil
end
```

**Note for the implementer:** `FoldersController` already has a `parent_path/1`. Before writing the copy above, check whether it is public or can be shared — if `Engram.Notes` exposes an equivalent, use that instead of duplicating. Duplicating a one-line path helper is acceptable; duplicating crypto is not (hence Task 1).

- [ ] **Step 4: Add the route**

In `lib/engram_web/router.ex`, inside the **vault-scoped** pipeline (the same block containing `get "/folders", FoldersController, :index` — around line 410), add:

```elixir
    # One read for the whole web file tree. See VaultTreeController's moduledoc
    # for why the per-folder endpoints could not serve this.
    get "/vault/tree", VaultTreeController, :show
```

It must sit in the vault-scoped pipeline so `conn.assigns.current_vault` is populated and `RequireOnboarding` gates it like `/api/notes`.

- [ ] **Step 5: Run the tests**

Run: `mix test test/engram_web/controllers/vault_tree_controller_test.exs`
Expected: PASS, all 6 tests.

- [ ] **Step 6: Commit**

```bash
git add lib/engram_web/controllers/vault_tree_controller.ex lib/engram_web/router.ex test/engram_web/controllers/vault_tree_controller_test.exs
git commit -m "feat(api): add GET /api/vault/tree bulk read for the web tree"
```

---

### Task 3: OpenAPI schema and spec regeneration

Without this the build fails — CI regenerates the spec and diffs it against the committed `openapi.json`.

**Files:**
- Create: `lib/engram_web/schemas/vault_tree.ex`
- Modify: `lib/engram_web/controllers/vault_tree_controller.ex`
- Modify: `openapi.json`

**Interfaces:**
- Produces: `EngramWeb.Schemas.VaultTreeResponse`

- [ ] **Step 1: Read a sibling schema first**

Run: `cat lib/engram_web/schemas/sync.ex`

Match its module naming, `OpenApiSpex.schema/1` structure, and how it is referenced from the controller. Do not invent a different style.

- [ ] **Step 2: Write the schema**

Create `lib/engram_web/schemas/vault_tree.ex` following the structure of `sync.ex`, defining `EngramWeb.Schemas.VaultTreeResponse` with properties `folders`, `notes`, `attachments`, `change_seq`, plus the `unchanged` boolean for the short-circuit response.

- [ ] **Step 3: Add the operation block to the controller**

Add `use OpenApiSpex.ControllerSpecs` under `use EngramWeb, :controller`, then above `def show`:

```elixir
  operation(:show,
    operation_id: "vault-tree",
    summary: "Get the whole vault tree in one read",
    tags: ["Vaults"],
    description:
      "Every folder, note and attachment the file tree renders, in one response. " <>
        "Pass `since_seq` (a prior response's `change_seq`) to short-circuit: when " <>
        "nothing has changed the body is just `{unchanged: true, change_seq}`.",
    parameters: [
      since_seq: [
        in: :query,
        type: :string,
        required: false,
        description: "Watermark from a prior response's `change_seq`; invalid values are ignored.",
        example: "1042"
      ]
    ],
    responses: [ok: {"Vault tree", "application/json", Schemas.VaultTreeResponse}]
  )
```

Add `alias EngramWeb.Schemas` to the alias block.

- [ ] **Step 4: Regenerate the committed spec**

```bash
MIX_ENV=test mix openapi.spec.json --spec EngramWeb.ApiSpec --pretty=true openapi.json
```

- [ ] **Step 5: Verify the spec matches what CI will generate**

```bash
MIX_ENV=test mix openapi.spec.json --spec EngramWeb.ApiSpec --pretty=true /tmp/openapi.generated.json
python3 -c "import json,sys; json.dump(json.load(open(sys.argv[1])), open(sys.argv[2],'w'), sort_keys=True, indent=2)" openapi.json /tmp/a.json
python3 -c "import json,sys; json.dump(json.load(open(sys.argv[1])), open(sys.argv[2],'w'), sort_keys=True, indent=2)" /tmp/openapi.generated.json /tmp/b.json
diff /tmp/a.json /tmp/b.json && echo "SPEC IN SYNC"
```

Expected: `SPEC IN SYNC`. This is the exact comparison the CI job performs.

- [ ] **Step 6: Commit**

```bash
git add lib/engram_web/schemas/vault_tree.ex lib/engram_web/controllers/vault_tree_controller.ex openapi.json
git commit -m "docs(api): document GET /api/vault/tree in the OpenAPI spec"
```

---

### Task 4: Client — fetch once, seed every cache

**Files:**
- Modify: `frontend/src/api/queries.ts`
- Test: `frontend/src/api/vault-tree.test.tsx` (create)

**Interfaces:**
- Consumes: `GET /api/vault/tree`
- Produces: `useVaultTree(): UseQueryResult<VaultTree>` and `seedTreeCaches(qc: QueryClient, vaultId: string, tree: VaultTree): void`

- [ ] **Step 1: Write the failing test**

Create `frontend/src/api/vault-tree.test.tsx`. Mirror the mocking style of the existing `frontend/src/api/queries.test.tsx` (`vi.mock("./client")` with a hoisted `get` spy, a `QueryClientProvider` wrapper, `useActiveVaultId` mocked to `"42"`).

```tsx
describe("seedTreeCaches", () => {
  it("seeds notes into their path-derived folder cache", () => {
    const qc = new QueryClient();
    seedTreeCaches(qc, "42", {
      folders: [{ id: "f1", name: "Projects", count: 1, parent_id: null }],
      notes: [
        { id: "n1", path: "Projects/spec.md", created_at: "s", updated_at: "s" },
        { id: "n2", path: "root.md", created_at: "s", updated_at: "s" },
      ],
      attachments: [],
      change_seq: 7,
    });

    const projects = qc.getQueryData(["folder-notes-by-id", "42", "f1"]);
    expect(projects).toHaveLength(1);
    expect(projects[0].id).toBe("n1");

    // Root notes live under the ROOT_FOLDER_ID sentinel, not under "".
    const root = qc.getQueryData(["folder-notes-by-id", "42", ROOT_FOLDER_ID]);
    expect(root).toHaveLength(1);
    expect(root[0].id).toBe("n2");
  });

  it("seeds the folders and attachments caches from the same response", () => {
    const qc = new QueryClient();
    seedTreeCaches(qc, "42", {
      folders: [{ id: "f1", name: "Projects", count: 0, parent_id: null }],
      notes: [],
      attachments: [
        { id: "a1", path: "img.png", mime_type: "image/png", size_bytes: 10 },
      ],
      change_seq: 1,
    });

    expect(qc.getQueryData(["folders", "42"])).toHaveLength(1);
    expect(qc.getQueryData(["attachments", "42"])).toHaveLength(1);
  });

  it("puts notes in a folder with no marker row under its synthetic id", () => {
    const qc = new QueryClient();
    seedTreeCaches(qc, "42", {
      folders: [],
      notes: [{ id: "n1", path: "Derived/a.md", created_at: "s", updated_at: "s" }],
      attachments: [],
      change_seq: 1,
    });

    // A folder with no backend marker carries a `syn:<path>` id — the loader
    // resolves it that way, so the seeded key must match or the row vanishes.
    const key = ["folder-notes-by-id", "42", syntheticFolderId("Derived")];
    expect(qc.getQueryData(key)).toHaveLength(1);
  });
});
```

- [ ] **Step 2: Confirm the exact cache keys before implementing**

Run these and read the output — the seeded keys must match byte-for-byte or the tree silently renders nothing:

```bash
cd frontend
grep -n '"folders", vaultId\|\["folders"' src/api/queries.ts
grep -n '"attachments", vaultId\|\["attachments"' src/api/queries.ts
grep -n 'ROOT_FOLDER_ID' src/api/queries.ts | head -5
grep -n 'export function syntheticFolderId\|isSyntheticFolderId' src/viewer/tree/synthesize-folders.ts
```

- [ ] **Step 3: Run the test to confirm it fails**

Run: `bunx vitest run src/api/vault-tree.test.tsx`
Expected: FAIL — `seedTreeCaches` is not exported.

- [ ] **Step 4: Implement**

In `frontend/src/api/queries.ts` add the types, the query hook, and the seeding function. Group notes by the folder portion of `path` (everything before the last `/`, or `ROOT_FOLDER_ID` when there is none), map folder path → folder id using the response's `folders`, and fall back to `syntheticFolderId(path)` for folders with no marker row. Fill the `NoteSummary` fields the tree does not read (`title`, `folder`, `tags`, `version`, `mtime`) with values derived from `path` or sensible defaults, so the cached rows still satisfy the existing `NoteSummary` type.

- [ ] **Step 5: Run the tests**

Run: `bunx vitest run src/api/vault-tree.test.tsx`
Expected: PASS, all 3 tests.

- [ ] **Step 6: Commit**

```bash
git add src/api/queries.ts src/api/vault-tree.test.tsx
git commit -m "feat(web): add useVaultTree and seed tree caches from one response"
```

---

### Task 5: Delete the fan-out

The actual bug. This task removes the loop and adds the regression guard that fails if it ever returns.

**Files:**
- Modify: `frontend/src/viewer/folder-tree.tsx:231-246`
- Test: `frontend/src/viewer/folder-tree.test.tsx`

**Interfaces:**
- Consumes: `useVaultTree`, `seedTreeCaches` from Task 4

- [ ] **Step 1: Write the failing regression test**

Add to `frontend/src/viewer/folder-tree.test.tsx`. The existing harness mocks `../api/queries` with `importActual` and a mutable `mock` fixture object — follow it.

```tsx
// The fan-out this whole change exists to kill: one request per folder,
// 20-33 of them, serialized 6-at-a-time by the HTTP/1.1 connection limit.
it("issues one tree request, not one per folder", async () => {
  mock.folders = [
    { id: "1", parent_id: null, name: "A", count: 0 },
    { id: "2", parent_id: null, name: "B", count: 0 },
    { id: "3", parent_id: null, name: "C", count: 0 },
  ];
  renderTree();
  await screen.findByRole("treeitem", { name: "A" });

  expect(fetchNotesForFolderIdSpy).not.toHaveBeenCalled();
});
```

Add `fetchNotesForFolderId` to the `vi.mock("../api/queries", ...)` factory as a hoisted spy so the test can assert it is never called on load.

- [ ] **Step 2: Run it to confirm it fails**

Run: `bunx vitest run src/viewer/folder-tree.test.tsx -t "issues one tree request"`
Expected: FAIL — the spy was called 3 times, once per folder.

- [ ] **Step 3: Delete the loop**

In `frontend/src/viewer/folder-tree.tsx`, delete the `bulkPrefetchedRef` declaration and the entire `useEffect` that loops `for (const f of folders) { prefetchFolderNotes(f.id); }` (the block commented "Bulk prefetch every folder's notes once after `useFolders` lands").

**Keep** `prefetchFolderNotes` itself — the hover-prefetch call site still uses it as a safety net for folders whose notes are somehow not in the seeded cache.

- [ ] **Step 4: Wire the tree query**

Call `useVaultTree()` in `FolderTree` and seed the caches in an effect when its data arrives.

- [ ] **Step 5: Run the full frontend suite**

Run: `bunx vitest run`
Expected: PASS. Pay attention to `folder-tree.test.tsx` and `note-page.test.tsx` — the seeded cache shape must satisfy every existing consumer.

- [ ] **Step 6: Commit**

```bash
git add src/viewer/folder-tree.tsx src/viewer/folder-tree.test.tsx
git commit -m "perf(web): replace per-folder tree fan-out with one bulk read"
```

---

### Task 6: Verify against a real browser

Unit tests cannot prove the request count dropped in a real app. Measure it the same way the problem was found.

- [ ] **Step 1: Bring up the dev stack against this worktree**

```bash
cd /home/open-claw/documents/code-projects/engram-workspace
make dev-selfhost BACKEND_DIR=$(pwd)/../engram/.worktrees/<this-worktree>
```

The worktree needs `.env.local`, `.env.local-selfhost`, `.env.local-saasdev` and `frontend/.env.local` copied from the main checkout — they are gitignored, so `git worktree add` does not bring them, and bring-up aborts without them.

- [ ] **Step 2: Count the requests**

Load the vault, then in the browser console:

```js
performance.getEntriesByType('resource')
  .filter(r => r.name.includes('/api/'))
  .map(r => r.name.replace(location.origin,'').split('?')[0])
  .reduce((a,p) => (a[p]=(a[p]||0)+1, a), {})
```

Expected: `/api/vault/tree` appears once; `/api/folders/list` does **not** appear at all. Before this change the same command returned 20–33 `/api/folders/list` entries.

- [ ] **Step 3: Confirm the queueing is gone**

```js
performance.getEntriesByType('resource')
  .filter(r => r.name.includes('/api/'))
  .map(r => ({ p: r.name.replace(location.origin,'').split('?')[0],
               queued: Math.round(r.requestStart - r.startTime),
               server: Math.round(r.responseStart - r.requestStart) }))
```

Expected: no entry with `queued` above ~50ms. The pre-change baseline was 5,626ms.

- [ ] **Step 4: Run the full backend gate, sequentially**

```bash
mix format --check-formatted
mix credo
mix dialyzer
mix test --warnings-as-errors
```

- [ ] **Step 5: Open the PR**

```bash
git push -u origin <branch>
GH_REPO=engram-app/Engram gh pr create --base main \
  --title "perf(web): one bulk read for the file tree" --body "..."
```

Include the before/after request counts and queue times in the PR body — they are the justification for the whole change.

---

## Self-Review

**Spec coverage:** Endpoint contract → Task 2. `since_seq` → Task 2 Step 1. Excluded fields → Task 2 (asserted by test). Both timestamps → Task 2. Client seeding → Task 4. Loop deletion → Task 5. Folder-id-mapping risk → Task 4 Step 2 + the synthetic-folder test. Attachment double-source risk → resolved by seeding one source (Deviation 2). Backend + frontend test lists → Tasks 2, 4, 5.

**Gap found and added:** The spec did not mention the OpenAPI CI gate. Without Task 3 the build fails. Added.

**Gap found and added:** The spec did not account for `path_aad`/`decrypt_path!` being private to `SyncController`. Added Task 1 rather than duplicating crypto.

**Type consistency:** `seedTreeCaches(qc, vaultId, tree)` is used with that signature in Tasks 4 and 5. Folder objects use `name` throughout (Tasks 2, 4), matching the existing `Folder` interface. `PathCrypto.aad/3` and `PathCrypto.decrypt!/4` are defined in Task 1 and called with those arities in Task 2.
