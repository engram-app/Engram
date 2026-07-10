# CRDT REST Yjs-Transport (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a backend REST transport for Yjs update bytes over the canonical server Y.Doc — two note-scoped `/updates` endpoints plus a vault-wide `/vault/heads` index — reusing the exact CRDT apply/persist/encrypt path the `crdt:` channel already uses, with **zero client behavior change** (nothing consumes them yet).

**Architecture:** A thin context module `Engram.Notes.CrdtTransport` holds all sync logic; a thin `EngramWeb.CrdtSyncController` exposes it over the existing vault-scoped API pipeline. Writes go through the canonical `:global` `SharedDoc` room (lossless `Yex.apply_update`, logged + encrypted by the room's existing `CrdtPersistence.update_v1` callback — no span-diff, no base_hash CAS). Reads rebuild the doc read-only (`CrdtBridge.doc_from_state` + `CrdtPersistence.replay_tail`) and emit a state-vector delta. The "head marker" is `sha256(state_vector)`.

**Tech Stack:** Elixir 1.17 / Phoenix 1.8, `y_ex` 0.10.x (`Yex.*`, Rust `yrs` NIF), Ecto/Postgres (RLS multi-tenant), ExUnit + ExMachina factories (`insert/2`), `Engram.DataCase` / `EngramWeb.ConnCase`.

## Global Constraints

- **Phase 1 is backend-only. No client change, no plugin change, no version-gated behavior.** These endpoints are dormant until Phase 2.
- **Single authority:** every write is a lossless `Yex.apply_update` onto the canonical doc. Never span-diff, never introduce a content-hash / base_hash CAS on this path. That seam is the exact bug class this redesign removes.
- **Encryption boundary (spec open Q#4):** update bytes are only ever persisted through the existing room path (`CrdtPersistence.update_v1` → `Crypto.encrypt_crdt_state/3`). The transport never writes plaintext and never adds a new at-rest encoding.
- **Head marker format:** `Base.url_encode64(:crypto.hash(:sha256, Yex.encode_state_vector!(doc)), padding: false)`. Same formula in all three endpoints so Phase 2/3 can compare markers across them.
- **Encodings:** update payloads travel base64 in/out of JSON (matches the attachments-upload precedent; avoids the octet-stream `Plug.Parsers` gap). The `since` state-vector is a **url-safe, unpadded** base64 query param.
- **`Repo.with_tenant/2` tenant id is `user.id`** (RLS tenant = user), exactly as `maybe_merge_crdt` wraps `replay_tail`. Verify on the first red→green that rows come back; a wrong tenant yields 0 rows loudly.
- **Never create a Y.Doc with `Yex.Doc.new`** — always via the CRDT infra (`CrdtBridge.new_doc/0` / `CrdtBridge.doc_from_state/1`), which sets `offset_kind: :utf16` (JS-Yjs wire compatibility).
- **Room teardown in tests:** any test that triggers `CrdtRegistry.ensure_started` MUST `on_exit(fn -> CrdtRegistry.terminate_room(note_id) end)` — a brutal kill that skips the unbind checkpoint, avoiding the `:global`-room-on-a-closed-sandbox-connection hazard.
- **Room-spawning tests run `async: false`** (`DataCase`/`ConnCase` give shared-mode sandbox when not async, so the internally-spawned room writes on the owner's connection). Pure read tests may be async.
- **Before opening the PR:** `mix format`, `mix credo --strict`, `mix sobelow` (pre-push gates on all three, not just compile), and the full `mix test` must be green. Bump `mix.exs` version once for the PR. Conventional-commit subject. No em dashes in commits/PR body.

---

### Task 1: `CrdtTransport` read path — `head_marker/1`, `read_delta/4`

**Files:**
- Create: `lib/engram/notes/crdt_transport.ex`
- Test: `test/engram/notes/crdt_transport_test.exs`

**Interfaces:**
- Consumes: `Engram.Notes.get_note_by_id/3 :: {:ok, Note.t()} | {:error, :not_found}`; `Engram.Crypto.decrypt_crdt_state/2 :: {:ok, binary()|nil} | {:error, term()}`; `Engram.Notes.CrdtBridge.doc_from_state/1 :: {:ok, Yex.Doc.t()} | {:error, term()}`; `Engram.Notes.CrdtPersistence.replay_tail/3 :: non_neg_integer()` (must run inside `Repo.with_tenant/2`); `Yex.encode_state_vector!/1 :: binary()`; `Yex.encode_state_as_update/1` and `/2 :: {:ok, binary()}`.
- Produces:
  - `head_marker(Yex.Doc.t()) :: String.t()`
  - `read_delta(user :: map(), vault :: map(), note_id :: String.t(), since_sv :: binary() | nil) :: {:ok, %{update: binary(), head: String.t()}} | {:error, :not_found}`
  - private `load_doc(user, vault, note_id) :: {:ok, Yex.Doc.t()} | {:error, :not_found}`

- [ ] **Step 1: Write the failing test**

Create `test/engram/notes/crdt_transport_test.exs`:

```elixir
defmodule Engram.Notes.CrdtTransportTest do
  # async: false — later tasks in this file spawn :global rooms; keep the whole
  # module on the shared-mode sandbox so room-spawning and read tests coexist.
  use Engram.DataCase, async: false

  alias Engram.Notes
  alias Engram.Notes.{CrdtBridge, CrdtRegistry, CrdtTransport}

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "TransportTest"})
    %{user: user, vault: vault}
  end

  describe "read_delta/4" do
    test "full state (since=nil) reconstructs the note text on a fresh client doc",
         %{user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{path: "T/A.md", content: "# A\n\nhello", mtime: 1_000.0})

      assert {:ok, %{update: update, head: head}} =
               CrdtTransport.read_delta(user, vault, note.id, nil)

      assert is_binary(update) and byte_size(update) > 0
      assert is_binary(head) and byte_size(head) > 0

      # Apply the returned full-state update to a brand-new client doc; it must
      # project the same body the server holds — proof the transport round-trips.
      client = CrdtBridge.new_doc()
      assert :ok = Yex.apply_update(client, update)
      assert CrdtBridge.body_of(client) =~ "hello"
    end

    test "delta (since=client SV) carries only the change after the client's state",
         %{user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{path: "T/B.md", content: "# B\n\none", mtime: 1_000.0})

      # Client catches up to the current server state, records its SV, THEN the
      # server advances. The delta since that SV must reproduce the new text.
      {:ok, %{update: full}} = CrdtTransport.read_delta(user, vault, note.id, nil)
      client = CrdtBridge.new_doc()
      :ok = Yex.apply_update(client, full)
      client_sv = Yex.encode_state_vector!(client)

      {:ok, _} =
        Notes.upsert_note(user, vault, %{path: "T/B.md", content: "# B\n\none two", mtime: 2_000.0})

      assert {:ok, %{update: delta}} = CrdtTransport.read_delta(user, vault, note.id, client_sv)
      assert :ok = Yex.apply_update(client, delta)
      assert CrdtBridge.body_of(client) =~ "two"
    end

    test "unknown note id → {:error, :not_found}", %{user: user, vault: vault} do
      assert {:error, :not_found} =
               CrdtTransport.read_delta(user, vault, Ecto.UUID.generate(), nil)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram/notes/crdt_transport_test.exs`
Expected: FAIL — `Engram.Notes.CrdtTransport` is undefined (`module ... is not available`).

- [ ] **Step 3: Write minimal implementation**

Create `lib/engram/notes/crdt_transport.ex`:

```elixir
defmodule Engram.Notes.CrdtTransport do
  @moduledoc """
  REST transport for Yjs update bytes over the canonical server Y.Doc.

  Phase 1 of the single-authority sync redesign (spec 2026-07-09). Provides the
  same lossless-merge apply path the `crdt:` channel uses, but over REST, so a
  client can flush queued CRDT ops when the channel is down and pull deltas for
  cold notes. No client consumes these yet.

  Writes go through the canonical `:global` `SharedDoc` room (its persistence
  callback encrypts + logs the update). Reads rebuild the doc read-only from the
  persisted snapshot + tail. Never span-diffs, never applies a base_hash CAS.
  """
  import Ecto.Query

  alias Engram.{Crypto, Notes, Repo}
  alias Engram.Notes.{CrdtBridge, CrdtPersistence, CrdtRegistry, Note}
  alias Yex.Sync.SharedDoc

  require Logger

  @doc "sha256(state vector), url-safe base64 no padding. THE head marker."
  @spec head_marker(Yex.Doc.t()) :: String.t()
  def head_marker(doc) do
    sv = Yex.encode_state_vector!(doc)
    Base.url_encode64(:crypto.hash(:sha256, sv), padding: false)
  end

  @doc """
  Return the Yjs update the client is missing plus the current head marker.

  `since_sv == nil` returns the full state; otherwise the delta after the
  client's state vector (`Yex.encode_state_as_update(doc, since_sv)`).
  """
  @spec read_delta(map(), map(), String.t(), binary() | nil) ::
          {:ok, %{update: binary(), head: String.t()}} | {:error, :not_found}
  def read_delta(user, vault, note_id, since_sv) do
    with {:ok, doc} <- load_doc(user, vault, note_id) do
      {:ok, update} =
        case since_sv do
          nil -> Yex.encode_state_as_update(doc)
          sv -> Yex.encode_state_as_update(doc, sv)
        end

      {:ok, %{update: update, head: head_marker(doc)}}
    end
  end

  # Read-only reconstruction of the canonical doc: persisted snapshot + tail
  # replay, exactly the recipe bind/3 and maybe_merge_crdt use. Spawns no room
  # and has no side effects. A decrypt/apply failure raises (loud) rather than
  # silently returning an empty doc.
  @spec load_doc(map(), map(), String.t()) :: {:ok, Yex.Doc.t()} | {:error, :not_found}
  defp load_doc(user, vault, note_id) do
    case Notes.get_note_by_id(user, vault, note_id) do
      {:ok, note} ->
        {:ok, snapshot} = Crypto.decrypt_crdt_state(note, user)
        {:ok, doc} = CrdtBridge.doc_from_state(snapshot)
        Repo.with_tenant(user.id, fn -> CrdtPersistence.replay_tail(doc, user, note_id) end)
        {:ok, doc}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/engram/notes/crdt_transport_test.exs`
Expected: PASS (3 tests). If `read_delta` returns an empty body, the tenant id in `Repo.with_tenant/2` is wrong — confirm it matches how `Notes.upsert_note`'s `maybe_merge_crdt` wraps `replay_tail` (it is `user.id`).

- [ ] **Step 5: Commit**

```bash
git add lib/engram/notes/crdt_transport.ex test/engram/notes/crdt_transport_test.exs
git commit -m "feat(crdt): REST Yjs read path (read_delta + head marker)"
```

---

### Task 2: `CrdtTransport.apply_update/4` — write through the canonical room

**Files:**
- Modify: `lib/engram/notes/crdt_transport.ex`
- Test: `test/engram/notes/crdt_transport_test.exs`

**Interfaces:**
- Consumes: `Engram.Notes.note_in_vault?/3 :: boolean()`; `CrdtRegistry.ensure_started(user_id, vault_id, note_id) :: {:ok, pid()} | {:error, term()}`; `CrdtRegistry.terminate_room/1 :: :ok`; `Yex.Sync.SharedDoc.update_doc(pid, (Yex.Doc.t() -> any)) :: any`; `Yex.Sync.SharedDoc.get_doc(pid) :: Yex.Doc.t()`; `Yex.apply_update(doc, binary) :: :ok | {:error, term()}`.
- Produces: `apply_update(user :: map(), vault :: map(), note_id :: String.t(), update :: binary()) :: {:ok, %{head: String.t()}} | {:error, :not_found | :invalid_update | :room_unavailable}` (`:room_unavailable` = room start/timeout/death; controller maps it to 503)

- [ ] **Step 1: Write the failing test**

Append to `test/engram/notes/crdt_transport_test.exs`, inside the module:

```elixir
  describe "apply_update/4" do
    test "a client update merges losslessly and advances the head", %{user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{path: "T/C.md", content: "# C\n\nseed", mtime: 1_000.0})

      on_exit(fn -> CrdtRegistry.terminate_room(note.id) end)

      # Build a real client update: catch up, edit locally, encode the delta.
      {:ok, %{update: full, head: head0}} = CrdtTransport.read_delta(user, vault, note.id, nil)
      client = CrdtBridge.new_doc()
      :ok = Yex.apply_update(client, full)
      before_sv = Yex.encode_state_vector!(client)
      CrdtBridge.ingest_plaintext(client, "# C\n\nseed and client edit")
      {:ok, client_update} = Yex.encode_state_as_update(client, before_sv)

      assert {:ok, %{head: head1}} =
               CrdtTransport.apply_update(user, vault, note.id, client_update)

      assert head1 != head0

      # The server now serves the client's edit back to a third, empty reader.
      {:ok, %{update: full2}} = CrdtTransport.read_delta(user, vault, note.id, nil)
      reader = CrdtBridge.new_doc()
      :ok = Yex.apply_update(reader, full2)
      assert CrdtBridge.body_of(reader) =~ "client edit"
    end

    test "garbage bytes → {:error, :invalid_update}", %{user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{path: "T/D.md", content: "# D", mtime: 1_000.0})

      on_exit(fn -> Engram.Notes.CrdtRegistry.terminate_room(note.id) end)

      assert {:error, :invalid_update} =
               CrdtTransport.apply_update(user, vault, note.id, <<255, 254, 253, 0, 1, 2>>)
    end

    test "note in another vault → {:error, :not_found}", %{user: user, vault: vault} do
      assert {:error, :not_found} =
               CrdtTransport.apply_update(user, vault, Ecto.UUID.generate(), <<0, 0>>)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram/notes/crdt_transport_test.exs -k apply_update`
Expected: FAIL — `function Engram.Notes.CrdtTransport.apply_update/4 is undefined`.

- [ ] **Step 3: Write minimal implementation**

Add to `lib/engram/notes/crdt_transport.ex` (after `read_delta/4`):

```elixir
  @doc """
  Apply a Yjs update to the canonical server doc through its live room.

  Idempotently starts the `:global` room, applies the update inside it (the
  room's persistence callback encrypts + appends it to the tail log and
  fastlanes it to live observers), and returns the new head marker.

  A malformed update yields `{:error, :invalid_update}` and mutates nothing.
  """
  @spec apply_update(map(), map(), String.t(), binary()) ::
          {:ok, %{head: String.t()}} | {:error, :not_found | :invalid_update}
  def apply_update(user, vault, note_id, update) do
    if Notes.note_in_vault?(user, vault.id, note_id) do
      {:ok, room} = CrdtRegistry.ensure_started(user.id, vault.id, note_id)
      parent = self()
      ref = make_ref()

      # SharedDoc.update_doc is a synchronous GenServer.call: the fun runs inside
      # the room and returns before update_doc does, so any {ref, :invalid}
      # message is already in our mailbox by the time we `receive ... after 0`.
      apply_in_room(room, note_id, fn doc ->
        case Yex.apply_update(doc, update) do
          :ok -> :ok
          {:error, _} -> send(parent, {ref, :invalid})
        end

        :ok
      end)

      receive do
        {^ref, :invalid} -> {:error, :invalid_update}
      after
        0 -> {:ok, %{head: head_marker(SharedDoc.get_doc(room))}}
      end
    else
      {:error, :not_found}
    end
  end

  # Run `fun` inside the room, tolerating benign exits (auto-exiting / shutting
  # room). A real crash/timeout is logged, not swallowed. Mirrors
  # CrdtDeliver.room_apply/3.
  defp apply_in_room(room, note_id, fun) do
    SharedDoc.update_doc(room, fun)
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {:normal, _} -> :ok
    :exit, {:shutdown, _} -> :ok
    :exit, reason ->
      Logger.error(
        "crdt transport room apply exited",
        Engram.Logging.Metadata.with_category(:error, :sync,
          note_id: note_id,
          reason: inspect(reason)
        )
      )

      :ok
  end
```

Note: confirm the `Metadata` module path used elsewhere in this app (`crdt_deliver.ex` calls `Metadata.with_category/3` via an alias). If `crdt_deliver.ex` has `alias Engram.Logging.Metadata` (or similar), add the same `alias` at the top of `crdt_transport.ex` and call `Metadata.with_category(...)` to match; do not invent a new module.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/engram/notes/crdt_transport_test.exs`
Expected: PASS (6 tests). Watch for zero "unbind"/"checkpoint" error logs at teardown — the `on_exit` `terminate_room` prevents them.

- [ ] **Step 5: Commit**

```bash
git add lib/engram/notes/crdt_transport.ex test/engram/notes/crdt_transport_test.exs
git commit -m "feat(crdt): REST Yjs write path (apply_update through room)"
```

---

### Task 3: `CrdtTransport.vault_heads/2` — per-note head index

**Files:**
- Modify: `lib/engram/notes/crdt_transport.ex`
- Test: `test/engram/notes/crdt_transport_test.exs`

**Interfaces:**
- Consumes: `read_delta/4` (Task 1); `Engram.Notes.Note` schema (`id`, `vault_id` fields); `Repo.with_tenant/2`.
- Produces: `vault_heads(user :: map(), vault :: map()) :: %{String.t() => String.t()}` (note_id → head marker).

- [ ] **Step 1: Write the failing test**

Append to `test/engram/notes/crdt_transport_test.exs`, inside the module:

```elixir
  describe "vault_heads/2" do
    test "returns a marker per note and only the edited note's marker changes",
         %{user: user, vault: vault} do
      {:ok, a} = Notes.upsert_note(user, vault, %{path: "H/A.md", content: "# A", mtime: 1_000.0})
      {:ok, b} = Notes.upsert_note(user, vault, %{path: "H/B.md", content: "# B", mtime: 1_000.0})

      heads0 = CrdtTransport.vault_heads(user, vault)
      assert Map.has_key?(heads0, a.id)
      assert Map.has_key?(heads0, b.id)

      {:ok, _} =
        Notes.upsert_note(user, vault, %{path: "H/A.md", content: "# A edited", mtime: 2_000.0})

      heads1 = CrdtTransport.vault_heads(user, vault)
      assert heads1[a.id] != heads0[a.id], "edited note's head must advance"
      assert heads1[b.id] == heads0[b.id], "untouched note's head must be stable"
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram/notes/crdt_transport_test.exs -k vault_heads`
Expected: FAIL — `function Engram.Notes.CrdtTransport.vault_heads/2 is undefined`.

- [ ] **Step 3: Write minimal implementation**

Add to `lib/engram/notes/crdt_transport.ex`:

```elixir
  @doc """
  Map every note in the vault to its head marker so a client can diff against
  its local per-note heads and learn which cold notes advanced.
  """
  @spec vault_heads(map(), map()) :: %{String.t() => String.t()}
  def vault_heads(user, vault) do
    # ponytail: rebuilds every note's doc read-only — O(notes) NIF work per call,
    # and read_delta also decrypts each note's content it then discards. NO client
    # polls this in Phase 1; it is dormant until Phase 3. Upgrade path (spec open
    # Q#1): persist a `crdt_head` column updated in update_v1/checkpoint, or ETag
    # the index, before any client polls it at scale.
    ids =
      Repo.with_tenant(user.id, fn ->
        Note
        |> where([n], n.vault_id == ^vault.id)
        |> select([n], n.id)
        |> Repo.all()
      end)

    Map.new(ids, fn note_id ->
      {:ok, %{head: head}} = read_delta(user, vault, note_id, nil)
      {note_id, head}
    end)
  end
```

Note: if `Engram.Notes.Note` carries a soft-delete column (e.g. `deleted_at`), add `and is_nil(n.deleted_at)` to the `where` so tombstoned notes are excluded — match whatever predicate `Notes`' existing list functions use. Confirm the column name before adding it; if none exists, leave the query as shown.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/engram/notes/crdt_transport_test.exs`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/engram/notes/crdt_transport.ex test/engram/notes/crdt_transport_test.exs
git commit -m "feat(crdt): vault head index (vault_heads)"
```

---

### Task 4: HTTP surface — `CrdtSyncController` + routes

**Files:**
- Create: `lib/engram_web/controllers/crdt_sync_controller.ex`
- Modify: `lib/engram_web/router.ex` (vault-scoped `scope "/api", EngramWeb`, the notes block — add the three routes BEFORE `get "/notes/*path"`)
- Test: `test/engram_web/controllers/crdt_sync_controller_test.exs`

**Interfaces:**
- Consumes: `CrdtTransport.apply_update/4`, `CrdtTransport.read_delta/4`, `CrdtTransport.vault_heads/2` (Tasks 1-3); `conn.assigns.current_user`, `conn.assigns.current_vault` (set by the pipeline's `Auth` + `VaultPlug`); `EngramWeb.ConnCase` helper `authed_api_conn` (setup provides an authed `conn` bound to a user + vault).
- Produces: routes
  - `POST /api/notes/:id/updates` → `:post_update`, body `{"update": "<base64>"}`, 200 `{"head": "<marker>"}`
  - `GET  /api/notes/:id/updates?since=<url-b64 sv>` → `:get_updates`, 200 `{"update": "<base64>", "head": "<marker>"}`
  - `GET  /api/vault/heads` → `:vault_heads`, 200 `{"heads": {"<note_id>": "<marker>"}}`

- [ ] **Step 1: Write the failing test**

Create `test/engram_web/controllers/crdt_sync_controller_test.exs`:

```elixir
defmodule EngramWeb.CrdtSyncControllerTest do
  # async: false — POST /updates starts a :global CRDT room that writes to the
  # DB; shared-mode sandbox (non-async) lets that internal process use the
  # owner's connection.
  use EngramWeb.ConnCase, async: false

  alias Engram.Notes
  alias Engram.Notes.{CrdtBridge, CrdtRegistry}

  setup :authed_api_conn

  # authed_api_conn provides %{conn, user, vault}. If it does not expose user +
  # vault, read them from conn.assigns after the pipeline runs, or add them here
  # from the same fixtures authed_api_conn uses.
  defp seed_note(user, vault, path, content) do
    {:ok, note} = Notes.upsert_note(user, vault, %{path: path, content: content, mtime: 1_000.0})
    note
  end

  describe "GET /api/notes/:id/updates" do
    test "returns full state that reconstructs the note", %{conn: conn, user: user, vault: vault} do
      note = seed_note(user, vault, "T/A.md", "# A\n\nhello")

      resp = conn |> get("/api/notes/#{note.id}/updates") |> json_response(200)
      assert %{"update" => b64, "head" => head} = resp
      assert is_binary(head)

      {:ok, update} = Base.decode64(b64)
      client = CrdtBridge.new_doc()
      :ok = Yex.apply_update(client, update)
      assert CrdtBridge.body_of(client) =~ "hello"
    end

    test "404 for a note not in this vault", %{conn: conn} do
      conn = get(conn, "/api/notes/#{Ecto.UUID.generate()}/updates")
      assert json_response(conn, 404)
    end

    test "400 for a non-uuid id", %{conn: conn} do
      conn = get(conn, "/api/notes/not-a-uuid/updates")
      assert json_response(conn, 400)
    end
  end

  describe "POST /api/notes/:id/updates" do
    test "applies a client update and round-trips through GET",
         %{conn: conn, user: user, vault: vault} do
      note = seed_note(user, vault, "T/B.md", "# B\n\nseed")
      on_exit(fn -> CrdtRegistry.terminate_room(note.id) end)

      # Build a real client update.
      full = conn |> get("/api/notes/#{note.id}/updates") |> json_response(200)
      {:ok, full_bytes} = Base.decode64(full["update"])
      client = CrdtBridge.new_doc()
      :ok = Yex.apply_update(client, full_bytes)
      before_sv = Yex.encode_state_vector!(client)
      CrdtBridge.ingest_plaintext(client, "# B\n\nseed plus edit")
      {:ok, delta} = Yex.encode_state_as_update(client, before_sv)

      post_resp =
        conn
        |> post("/api/notes/#{note.id}/updates", %{update: Base.encode64(delta)})
        |> json_response(200)

      assert %{"head" => _} = post_resp

      # GET now serves the edit back.
      after_full = conn |> get("/api/notes/#{note.id}/updates") |> json_response(200)
      {:ok, after_bytes} = Base.decode64(after_full["update"])
      reader = CrdtBridge.new_doc()
      :ok = Yex.apply_update(reader, after_bytes)
      assert CrdtBridge.body_of(reader) =~ "plus edit"
    end

    test "422 for an update that fails to apply", %{conn: conn, user: user, vault: vault} do
      note = seed_note(user, vault, "T/C.md", "# C")
      on_exit(fn -> CrdtRegistry.terminate_room(note.id) end)

      conn =
        post(conn, "/api/notes/#{note.id}/updates", %{update: Base.encode64(<<255, 254, 0, 1>>)})

      assert json_response(conn, 422)
    end

    test "400 when the update field is missing", %{conn: conn, user: user, vault: vault} do
      note = seed_note(user, vault, "T/E.md", "# E")
      conn = post(conn, "/api/notes/#{note.id}/updates", %{})
      assert json_response(conn, 400)
    end

    test "401 without auth", %{conn: conn, user: user, vault: vault} do
      note = seed_note(user, vault, "T/F.md", "# F")

      conn =
        conn
        |> delete_req_header("authorization")
        |> post("/api/notes/#{note.id}/updates", %{update: Base.encode64(<<0, 0>>)})

      assert json_response(conn, 401)
    end
  end

  describe "GET /api/vault/heads" do
    test "returns a marker map covering the vault's notes",
         %{conn: conn, user: user, vault: vault} do
      a = seed_note(user, vault, "H/A.md", "# A")
      b = seed_note(user, vault, "H/B.md", "# B")

      heads = conn |> get("/api/vault/heads") |> json_response(200) |> Map.fetch!("heads")
      assert Map.has_key?(heads, a.id)
      assert Map.has_key?(heads, b.id)
    end
  end
end
```

If `authed_api_conn` does not yield `user` and `vault` in the context, adjust `seed_note` calls to pull them from `conn.assigns.current_user` / `conn.assigns.current_vault` after any request, or extend the setup to surface them (mirror how `NotesControllerTest` obtains the acting user/vault).

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram_web/controllers/crdt_sync_controller_test.exs`
Expected: FAIL — no route matches `/api/notes/:id/updates` (Phoenix `NoRouteError`) or `CrdtSyncController` undefined.

- [ ] **Step 3a: Create the controller**

Create `lib/engram_web/controllers/crdt_sync_controller.ex`:

```elixir
defmodule EngramWeb.CrdtSyncController do
  @moduledoc """
  REST transport for Yjs updates (single-authority sync, Phase 1). Thin wrapper
  over `Engram.Notes.CrdtTransport`; auth + vault scoping come from the pipeline.
  """
  use EngramWeb, :controller

  alias Engram.Notes.CrdtTransport

  # POST /api/notes/:id/updates   body: {"update": "<base64 v1 update>"}
  def post_update(conn, %{"id" => id, "update" => b64}) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    with {:ok, note_id} <- cast_uuid(id),
         {:ok, update} <- decode_std(b64),
         {:ok, %{head: head}} <- CrdtTransport.apply_update(user, vault, note_id, update) do
      json(conn, %{head: head})
    else
      {:error, :bad_uuid} -> error(conn, 400, "invalid note id")
      {:error, :bad_base64} -> error(conn, 400, "invalid base64 update")
      {:error, :not_found} -> error(conn, 404, "note not found")
      {:error, :invalid_update} -> error(conn, 422, "update failed to apply")
      {:error, :room_unavailable} -> error(conn, 503, "sync room unavailable, retry")
    end
  end

  def post_update(conn, %{"id" => _}), do: error(conn, 400, "missing update")

  # GET /api/notes/:id/updates?since=<url-safe base64 state vector>
  def get_updates(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    with {:ok, note_id} <- cast_uuid(id),
         {:ok, since} <- decode_since(params["since"]),
         {:ok, %{update: update, head: head}} <-
           CrdtTransport.read_delta(user, vault, note_id, since) do
      json(conn, %{update: Base.encode64(update), head: head})
    else
      {:error, :bad_uuid} -> error(conn, 400, "invalid note id")
      {:error, :bad_since} -> error(conn, 400, "invalid since vector")
      {:error, :not_found} -> error(conn, 404, "note not found")
    end
  end

  # GET /api/vault/heads
  def vault_heads(conn, _params) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault
    json(conn, %{heads: CrdtTransport.vault_heads(user, vault)})
  end

  defp cast_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :bad_uuid}
    end
  end

  defp decode_std(b64) do
    case Base.decode64(b64) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, :bad_base64}
    end
  end

  defp decode_since(nil), do: {:ok, nil}

  defp decode_since(sv) do
    case Base.url_decode64(sv, padding: false) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, :bad_since}
    end
  end

  defp error(conn, status, message) do
    conn |> put_status(status) |> json(%{error: message})
  end
end
```

- [ ] **Step 3b: Add the routes**

In `lib/engram_web/router.ex`, inside the vault-scoped `scope "/api", EngramWeb do` block, in the notes area and **above** `get "/notes/*path"` (place next to the existing `/notes/by-id/:id` and `/notes/changes` specific routes):

```elixir
    post "/notes/:id/updates", CrdtSyncController, :post_update
    get "/notes/:id/updates", CrdtSyncController, :get_updates
    get "/vault/heads", CrdtSyncController, :vault_heads
```

Verify placement: run `mix phx.routes | grep -E "updates|vault/heads"` and confirm all three resolve to `EngramWeb.CrdtSyncController` and that `/notes/:id/updates` is listed before the `/notes/*path` catch-all.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/engram_web/controllers/crdt_sync_controller_test.exs`
Expected: PASS. If any request 404s where a note exists, the `/notes/*path` wildcard is intercepting — the new routes must be defined before it.

- [ ] **Step 5: Commit**

```bash
git add lib/engram_web/controllers/crdt_sync_controller.ex lib/engram_web/router.ex test/engram_web/controllers/crdt_sync_controller_test.exs
git commit -m "feat(crdt): REST /updates + /vault/heads endpoints"
```

---

### Task 5: Gauntlet + PR

**Files:** none (verification + version bump only)

- [ ] **Step 1: Bump the version once for the PR**

In `mix.exs`, bump the `version:` patch (single bump for the whole PR, per project convention).

```bash
git add mix.exs && git commit -m "chore: bump version for CRDT REST transport PR"
```

- [ ] **Step 2: Run the full pre-push gauntlet**

```bash
mix format
mix credo --strict
mix sobelow --config
mix test
```

Expected: format clean, zero credo issues, zero sobelow findings, all tests green (including the two new files). Fix anything red before proceeding — a red pre-existing test on this branch is in scope, not out of scope.

- [ ] **Step 3: Open the PR**

Push the branch and open a PR titled `feat(crdt): REST Yjs-update transport (Phase 1)`. Body: one-paragraph summary (dormant backend transport, no client change), link the design spec, and the three-endpoint contract. End with the Claude Code trailer. Do not merge; hand back for review.

---

## Self-Review

**1. Spec coverage (Phase 1 section of the design spec):**
- `POST /api/notes/:note_id/updates`, applied to canonical Y.Doc, lossless, returns head → Task 2 (`apply_update`) + Task 4 (route/controller). ✓
- `GET /api/notes/:note_id/updates?since=<sv>`, delta or full state → Task 1 (`read_delta`) + Task 4. ✓
- `GET /api/vault/heads` → `{note_id: head_marker}` → Task 3 (`vault_heads`) + Task 4. ✓
- Auth + vault scoping reuse existing pipeline → routes placed in the vault-scoped scope; controller reads `current_user`/`current_vault`. ✓
- Encryption at rest reuses `crdt_persistence` wrapping (open Q#4) → writes go through the room's `update_v1`/`Crypto.encrypt_crdt_state`; no new at-rest path. ✓ (Global Constraints + Task 2.)
- Head-marker format (open Q, resolved) → `sha256(state_vector)` url-b64, one formula everywhere. ✓
- Update-log read path (open Q, resolved) → `doc_from_state` + `replay_tail` + `encode_state_as_update(doc, sv)`. ✓ (Task 1.)
- Testing: REST `/updates` round-trip (POST bytes → GET delta) → Task 4; `/vault/heads` diff → Task 3. ✓
- Deferred to later phases (noted, not built): head-index scale/pagination/ETag (open Q#1), REST flush batching (open Q#2), update-log compaction (open Q#3), pool sizing (open Q#5), and all client-side send/receive (Phases 2-3). ✓

**2. Placeholder scan:** No "TBD"/"add error handling"/"similar to". Every code step shows full code. Two explicit *verification* notes (Metadata alias path in Task 2; soft-delete column in Task 3; `authed_api_conn` context shape in Task 4) are confirm-against-real-code steps, not placeholders — each names the exact thing to check and the fallback.

**3. Type consistency:** `head_marker/1`, `read_delta/4`, `apply_update/4`, `vault_heads/2` names + arities match between their defining task, the controller that calls them (Task 4), and the Interfaces blocks. Error atoms (`:not_found`, `:invalid_update`, `:bad_uuid`, `:bad_base64`, `:bad_since`) are consistent between `CrdtTransport`, the controller `with/else`, and the tests. Head marker is a `String.t()` everywhere; updates are raw `binary()` in the context layer and base64 `String.t()` only at the HTTP boundary.
