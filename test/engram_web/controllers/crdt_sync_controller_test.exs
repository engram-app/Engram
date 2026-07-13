defmodule EngramWeb.CrdtSyncControllerTest do
  # async: false — POST /updates starts a :global CRDT room that writes to the
  # DB; shared-mode sandbox (non-async) lets that internal process use the
  # owner's connection.
  use EngramWeb.ConnCase, async: false

  alias Engram.Notes
  alias Engram.Notes.{CrdtBridge, CrdtRegistry}

  setup :authed_api_conn

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

    test "404 for an unknown note id", %{conn: conn} do
      conn = get(conn, "/api/notes/#{Ecto.UUID.generate()}/updates")
      assert json_response(conn, 404)
    end

    test "400 for a non-uuid id", %{conn: conn} do
      conn = get(conn, "/api/notes/not-a-uuid/updates")
      assert json_response(conn, 400)
    end

    test "400 (not 500) when since is a repeated (list) query param", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      note = seed_note(user, vault, "T/H.md", "# H")

      # ?since[]=x parses to a list, not a scalar string — must 400, not crash.
      conn = get(conn, "/api/notes/#{note.id}/updates?since[]=x")
      assert json_response(conn, 400)
    end

    test "400 (not 500) when since is valid base64 but not a real state vector", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      note = seed_note(user, vault, "T/I.md", "# I")

      since = Base.url_encode64(:binary.copy(<<0x80>>, 10), padding: false)
      conn = get(conn, "/api/notes/#{note.id}/updates?since=#{since}")
      assert json_response(conn, 400)
    end

    test "400 (not a VM-crashing NIF call) when since claims an implausible entry count", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      note = seed_note(user, vault, "T/J.md", "# J")

      # <<128, 128, 128, 128, 15>> decodes as a state vector claiming ~2^31
      # client entries in 5 bytes — see CrdtTransport.plausible_state_vector?/1.
      # Unguarded, this crashes the whole BEAM VM (Rust allocator abort), not
      # just this request; this test proves the guard rejects it as bad input.
      since = Base.url_encode64(<<128, 128, 128, 128, 15>>, padding: false)
      conn = get(conn, "/api/notes/#{note.id}/updates?since=#{since}")
      assert json_response(conn, 400)
    end

    test "accepts a STANDARD-base64 since vector (plugin encodes with btoa, not url-safe)",
         %{conn: conn, user: user, vault: vault} do
      note = seed_note(user, vault, "T/K.md", "# K\n\nhello")

      # <<1, 1, 63>> is a valid 1-client state vector (id=1, clock=63) whose
      # STANDARD base64 is "AQE/" — it contains '/', which the url-safe alphabet
      # lacks. The plugin encodes `since` with standard base64 (btoa), so every
      # non-genesis cold-receive delta pull 400'd here; empty "AA==" vectors have
      # no +// and masked it. Regression guard for the e2e-clerk test_85
      # missed-delivery convergence failure (cold-receive was 100% broken for
      # non-empty state vectors).
      since = Base.encode64(<<1, 1, 63>>)
      assert String.contains?(since, "/")

      resp =
        conn
        |> get("/api/notes/#{note.id}/updates?since=#{URI.encode_www_form(since)}")
        |> json_response(200)

      assert %{"update" => _} = resp
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

    test "400 (not 500) when update is not a string", %{conn: conn, user: user, vault: vault} do
      note = seed_note(user, vault, "T/G.md", "# G")

      # A JSON integer (not a base64 string) must be rejected as bad input, not crash.
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/notes/#{note.id}/updates", Jason.encode!(%{"update" => 123}))

      assert json_response(conn, 400)
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
