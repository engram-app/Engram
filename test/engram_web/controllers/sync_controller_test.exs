defmodule EngramWeb.SyncControllerTest do
  use EngramWeb.ConnCase, async: true

  import ExUnit.CaptureLog

  setup %{conn: conn} do
    user = insert(:user)
    # Free-tier launch §4.5 — attachment uploads now gate on attachments_enabled,
    # which is paid-only. Tests that POST to /api/attachments need an active
    # Pro subscription to clear the controller gate.
    insert(:subscription, user: user, tier: "pro", status: "active")
    vault = insert(:vault, user: user, is_default: true)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    grant_api_write!(user)
    authed = put_req_header(conn, "authorization", "Bearer #{api_key}")
    %{conn: authed, user: user, vault: vault}
  end

  describe "GET /sync/manifest" do
    test "returns empty manifest for new user", %{conn: conn} do
      conn = get(conn, "/api/sync/manifest")
      body = json_response(conn, 200)

      assert body["notes"] == []
      assert body["attachments"] == []
      assert body["total_notes"] == 0
      assert body["total_attachments"] == 0
      # zero-write vault → change_seq bootstrap floor is 0
      assert body["change_seq"] == 0
    end

    test "includes notes with path and content_hash", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Test/A.md", content: "# Alpha", mtime: 1_000.0})
      post(conn, "/api/notes", %{path: "Test/B.md", content: "# Beta", mtime: 1_000.0})

      conn2 = get(conn, "/api/sync/manifest")
      body = json_response(conn2, 200)

      assert body["total_notes"] == 2
      assert length(body["notes"]) == 2

      note = Enum.find(body["notes"], &(&1["path"] == "Test/A.md"))
      assert is_binary(note["content_hash"])
    end

    test "includes each note's CORRECT stable id (client id reconciliation hook)",
         %{conn: conn, user: user, vault: vault} do
      # The plugin uses this to learn the authoritative note_id for every
      # existing note on an id-keying upgrade, instead of minting divergent
      # ids (the 2026-07-06 corruption trigger). The id must be the note's
      # ACTUAL id — a wrong-but-valid UUID would re-create the divergence.
      post(conn, "/api/notes", %{path: "Test/A.md", content: "# Alpha", mtime: 1_000.0})
      # The POST provisioned the DEK in the DB, but the in-struct context user
      # is stale — load it so get_note's path_hmac derivation resolves.
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      {:ok, real} = Engram.Notes.get_note(user, vault, "Test/A.md")

      body = conn |> get("/api/sync/manifest") |> json_response(200)
      note = Enum.find(body["notes"], &(&1["path"] == "Test/A.md"))

      assert note["id"] == real.id
    end

    test "includes each attachment's stable id", %{conn: conn} do
      post(conn, "/api/attachments", %{
        path: "photos/img.png",
        content_base64: Base.encode64("binary data"),
        mtime: 1_000.0
      })

      body = conn |> get("/api/sync/manifest") |> json_response(200)
      att = hd(body["attachments"])

      assert {:ok, _} = Ecto.UUID.cast(att["id"]),
             "manifest attachment must carry a valid UUID id, got: #{inspect(att["id"])}"
    end

    test "includes attachments with path and content_hash", %{conn: conn} do
      post(conn, "/api/attachments", %{
        path: "photos/img.png",
        content_base64: Base.encode64("binary data"),
        mtime: 1_000.0
      })

      conn2 = get(conn, "/api/sync/manifest")
      body = json_response(conn2, 200)

      assert body["total_attachments"] == 1
      att = hd(body["attachments"])
      assert att["path"] == "photos/img.png"
      assert is_binary(att["content_hash"])
    end

    test "emits decrypt-batch telemetry for manifest paths", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Tel/A.md", content: "# A", mtime: 1_000.0})
      post(conn, "/api/notes", %{path: "Tel/B.md", content: "# B", mtime: 1_000.0})

      ref =
        :telemetry_test.attach_event_handlers(self(), [[:engram, :crypto, :decrypt_batch]])

      conn2 = get(conn, "/api/sync/manifest")
      assert json_response(conn2, 200)["total_notes"] == 2

      assert_receive {[:engram, :crypto, :decrypt_batch], ^ref, measurements,
                      %{kind: :manifest_notes}}

      assert measurements.count == 2
      assert is_integer(measurements.duration_us)
    end

    test "excludes deleted notes and attachments", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Test/Del.md", content: "# Del", mtime: 1_000.0})
      delete(conn, "/api/notes/Test/Del.md")

      post(conn, "/api/attachments", %{
        path: "photos/del.png",
        content_base64: Base.encode64("data"),
        mtime: 1_000.0
      })

      delete(conn, "/api/attachments/photos/del.png")

      conn2 = get(conn, "/api/sync/manifest")
      body = json_response(conn2, 200)

      assert body["total_notes"] == 0
      assert body["total_attachments"] == 0
    end

    test "returns 401 without auth", %{conn: conn} do
      conn =
        conn
        |> delete_req_header("authorization")
        |> get("/api/sync/manifest")

      assert json_response(conn, 401)
    end

    test "omits folder marker rows", %{conn: conn, user: user, vault: vault} do
      # Folder markers have path_ciphertext=nil; if the manifest query doesn't
      # filter by kind='note', `decrypt_path!` raises and the endpoint 500s.
      {:ok, _marker} = Engram.Notes.create_folder_marker(user, vault, "EmptyFolder")

      post(conn, "/api/notes", %{path: "Real.md", content: "# real", mtime: 1_000.0})

      conn2 = get(conn, "/api/sync/manifest")
      body = json_response(conn2, 200)

      assert body["total_notes"] == 1
      paths = Enum.map(body["notes"], & &1["path"])
      assert paths == ["Real.md"]
    end
  end

  describe "GET /sync/manifest — seq-diff validator (Phase E1, #1065)" do
    test "note rows carry seq + crdt_head; attachment rows carry seq", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Test/A.md", content: "# Alpha", mtime: 1_000.0})

      body = conn |> get("/api/sync/manifest") |> json_response(200)
      [note] = body["notes"]

      assert is_integer(note["seq"]) and note["seq"] > 0
      assert Map.has_key?(note, "crdt_head")
    end

    test "since_seq equal to the watermark short-circuits to unchanged", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Test/A.md", content: "# Alpha", mtime: 1_000.0})
      %{"change_seq" => seq} = conn |> get("/api/sync/manifest") |> json_response(200)

      body = conn |> get("/api/sync/manifest?since_seq=#{seq}") |> json_response(200)

      assert body["unchanged"] == true
      assert body["change_seq"] == seq
      refute Map.has_key?(body, "notes")
    end

    test "stale since_seq returns the full manifest", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Test/A.md", content: "# Alpha", mtime: 1_000.0})

      body = conn |> get("/api/sync/manifest?since_seq=0") |> json_response(200)

      assert is_list(body["notes"])
      refute body["unchanged"]
    end

    test "garbage since_seq is ignored (full manifest, no 500)", %{conn: conn} do
      body = conn |> get("/api/sync/manifest?since_seq=abc") |> json_response(200)

      assert is_list(body["notes"])
    end

    test "zero-write vault with since_seq=0 short-circuits (floor is the watermark)", %{
      conn: conn
    } do
      body = conn |> get("/api/sync/manifest?since_seq=0") |> json_response(200)

      assert body["unchanged"] == true
      assert body["change_seq"] == 0
    end
  end

  describe "GET /sync/manifest — DEK failures" do
    # `{:error, :no_dek}` means a brand-new user with zero writes, and an
    # empty manifest is the honest answer. Any OTHER crypto error is not
    # "you have no notes" — and the manifest is the one endpoint where
    # saying that is actively destructive: the plugin diffs the manifest
    # against the local vault, so an empty one reads as "everything was
    # deleted remotely". Fail loudly instead. See PR #1316 review follow-up.
    test "unexpected crypto error raises rather than rendering an empty manifest", %{
      conn: conn,
      user: user
    } do
      # Same corruption technique as vault_tree_controller_test — a garbage
      # encrypted_dek blob makes Crypto.get_dek/1 return
      # {:error, :unrecognised_blob}.
      corrupt = Ecto.Changeset.change(user, encrypted_dek: :crypto.strong_rand_bytes(32))
      {:ok, _corrupt_user} = Engram.Repo.update(corrupt, skip_tenant_check: true)

      log =
        capture_log(fn ->
          assert_error_sent(500, fn -> get(conn, "/api/sync/manifest") end)
        end)

      assert log =~ "sync manifest: DEK unavailable"
    end
  end
end

defmodule EngramWeb.SyncControllerTenantBlocksTest do
  # async: false: these count with_tenant blocks over a request, and the
  # request-lookup caches they depend on are node-global; an async test's
  # setup clears them (see Engram.DataCase.clear_request_caches/0).
  use EngramWeb.ConnCase, async: false

  alias Engram.TenantQueryCounter

  # A real vault (register_vault encrypts its name): the factory's random name
  # bytes do not decrypt, and an undecryptable vault list is never cached, so
  # the warm state would not be the one prod runs in.
  setup %{conn: conn} do
    user = insert(:user)
    insert(:subscription, user: user, tier: "pro", status: "active")
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Blocks", Ecto.UUID.generate())
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    grant_api_write!(user)
    authed = put_req_header(conn, "authorization", "Bearer #{api_key}")
    %{conn: authed, user: user, vault: vault}
  end

  # Caches cleared, then warmed by one identical request (a long-lived prod
  # node's steady state), then the measured request.
  defp warm_then_count(fun) do
    Engram.DataCase.clear_request_caches()
    fun.()
    TenantQueryCounter.count_tenant_enters(fun)
  end

  defp assert_blocks(enters, n) do
    assert length(enters) == n, "expected #{n} with_tenant blocks, got #{length(enters)}"
  end

  describe "GET /sync/manifest with_tenant round trips (#1211)" do
    # Warm request caches, the steady state of a long-lived node: Auth's
    # subscription preload (#1758) and VaultPlug's vault resolve are cache hits
    # and open no block. What remains is the controller's own work.
    test "with warm request caches, a changed manifest opens exactly 1 with_tenant block",
         %{conn: conn} do
      post(conn, "/api/notes", %{path: "A.md", content: "# A", mtime: 1_000.0})

      post(conn, "/api/attachments", %{
        path: "img.png",
        content_base64: Base.encode64("hi"),
        mtime: 1_000.0
      })

      # The seq read and the notes/attachments fetch share one block (was 4
      # before #1211 collapsed the notes and attachments blocks, 2 before
      # Task 10b folded the seq read in).
      warm_then_count(fn -> conn |> get("/api/sync/manifest") |> json_response(200) end)
      |> assert_blocks(1)
    end

    test "with warm request caches, an unchanged manifest opens exactly 1 with_tenant block",
         %{conn: conn} do
      post(conn, "/api/notes", %{path: "A.md", content: "# A", mtime: 1_000.0})

      current =
        conn |> get("/api/sync/manifest") |> json_response(200) |> Map.fetch!("change_seq")

      # The seq read only: the short-circuit skips notes/attachments.
      warm_then_count(fn ->
        conn |> get("/api/sync/manifest?since_seq=#{current}") |> json_response(200)
      end)
      |> assert_blocks(1)
    end
  end
end
