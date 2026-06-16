defmodule EngramWeb.NotesControllerTest do
  use EngramWeb.ConnCase, async: true

  setup :authed_api_conn

  # ---------------------------------------------------------------------------
  # POST /notes
  # ---------------------------------------------------------------------------

  describe "POST /notes" do
    test "creates a note and returns metadata", %{conn: conn} do
      conn =
        post(conn, "/api/notes", %{
          path: "Test/Hello World.md",
          content: "---\ntags: [health, omega]\n---\n# Hello World\n\nBody.",
          mtime: 1_709_234_567.0
        })

      assert %{"note" => note} = json_response(conn, 200)
      assert note["path"] == "Test/Hello World.md"
      assert note["title"] == "Hello World"
      assert note["folder"] == "Test"
      assert note["tags"] == ["health", "omega"]
      assert note["version"] == 1
    end

    test "upserts an existing note and increments version", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Test/File.md", content: "# v1", mtime: 1_000.0})

      conn2 = post(conn, "/api/notes", %{path: "Test/File.md", content: "# v2", mtime: 2_000.0})

      assert %{"note" => note} = json_response(conn2, 200)
      assert note["version"] == 2
    end

    test "sanitizes illegal chars in path", %{conn: conn} do
      conn =
        post(conn, "/api/notes", %{
          path: "Test/Why do I resist?.md",
          content: "# Why",
          mtime: 1_000.0
        })

      assert %{"note" => note} = json_response(conn, 200)
      assert note["path"] == "Test/Why do I resist.md"
    end

    test "returns 422 when path is missing", %{conn: conn} do
      conn = post(conn, "/api/notes", %{content: "# Hello", mtime: 1_000.0})
      assert json_response(conn, 422)
    end

    test "returns 401 without auth", %{conn: conn} do
      conn =
        conn
        |> delete_req_header("authorization")
        |> post("/api/notes", %{path: "Test/A.md", content: "x", mtime: 1_000.0})

      assert json_response(conn, 401)
    end
  end

  # ---------------------------------------------------------------------------
  # Version conflict (409)
  # ---------------------------------------------------------------------------

  describe "POST /notes version conflict" do
    test "returns 409 when client version doesn't match server version", %{conn: conn} do
      # Create note (version 1)
      post(conn, "/api/notes", %{path: "Test/Conflict.md", content: "# v1", mtime: 1_000.0})

      # Update note (version 2)
      post(conn, "/api/notes", %{path: "Test/Conflict.md", content: "# v2", mtime: 2_000.0})

      # Client still thinks it's version 1 — should get 409
      conn2 =
        post(conn, "/api/notes", %{
          path: "Test/Conflict.md",
          content: "# v1-modified",
          mtime: 3_000.0,
          version: 1
        })

      assert %{"conflict" => true, "server_note" => server_note} =
               json_response(conn2, 409)

      assert server_note["path"] == "Test/Conflict.md"
      assert server_note["version"] == 2
      assert server_note["content"] == "# v2"
    end

    test "succeeds when client version matches server version", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Test/Match.md", content: "# v1", mtime: 1_000.0})

      conn2 =
        post(conn, "/api/notes", %{
          path: "Test/Match.md",
          content: "# v2",
          mtime: 2_000.0,
          version: 1
        })

      assert %{"note" => note} = json_response(conn2, 200)
      assert note["version"] == 2
    end

    test "ignores version check on new note creation", %{conn: conn} do
      conn =
        post(conn, "/api/notes", %{
          path: "Test/New.md",
          content: "# New",
          mtime: 1_000.0,
          version: 1
        })

      assert %{"note" => note} = json_response(conn, 200)
      assert note["version"] == 1
    end

    test "allows upsert without version param (backwards compatible)", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Test/NoVer.md", content: "# v1", mtime: 1_000.0})

      conn2 = post(conn, "/api/notes", %{path: "Test/NoVer.md", content: "# v2", mtime: 2_000.0})
      assert %{"note" => note} = json_response(conn2, 200)
      assert note["version"] == 2
    end
  end

  # ---------------------------------------------------------------------------
  # POST /notes/append
  # ---------------------------------------------------------------------------

  describe "POST /notes/append" do
    test "appends text to an existing note", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Test/Append.md", content: "# Hello", mtime: 1_000.0})

      conn2 = post(conn, "/api/notes/append", %{path: "Test/Append.md", text: "\nWorld!"})
      assert %{"note" => note} = json_response(conn2, 200)
      assert note["content"] =~ "# Hello"
      assert note["content"] =~ "World!"
    end

    test "creates new note when note doesn't exist", %{conn: conn} do
      conn = post(conn, "/api/notes/append", %{path: "Nope/Missing.md", text: "stuff"})
      resp = json_response(conn, 200)
      assert resp["created"] == true
      assert resp["path"] == "Nope/Missing.md"
      assert resp["note"]["content"] =~ "stuff"
    end

    test "returns 401 without auth", %{conn: conn} do
      conn =
        conn
        |> delete_req_header("authorization")
        |> post("/api/notes/append", %{path: "a.md", text: "x"})

      assert json_response(conn, 401)
    end
  end

  # ---------------------------------------------------------------------------
  # GET /notes/:path
  # ---------------------------------------------------------------------------

  describe "GET /notes/:path" do
    test "returns note by path", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Test/Readable.md", content: "# Readable", mtime: 1_000.0})

      conn = get(conn, "/api/notes/Test/Readable.md")
      assert body = json_response(conn, 200)
      assert body["path"] == "Test/Readable.md"
    end

    test "GET /api/notes/:path includes numeric id", %{conn: conn, user: user, vault: vault} do
      {:ok, note} =
        Engram.Notes.upsert_note(user, vault, %{
          "path" => "id-check.md",
          "content" => "# A",
          "mtime" => 1_000.0
        })

      conn = get(conn, "/api/notes/id-check.md")
      body = json_response(conn, 200)
      assert body["id"] == note.id
      assert is_binary(body["id"])
    end

    test "returns 404 for missing note", %{conn: conn} do
      conn = get(conn, "/api/notes/Nope/Missing.md")
      assert json_response(conn, 404)
    end

    test "returns 404 for deleted note", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Test/Gone.md", content: "# Gone", mtime: 1_000.0})
      delete(conn, "/api/notes/Test/Gone.md")

      conn = get(conn, "/api/notes/Test/Gone.md")
      assert json_response(conn, 404)
    end

    test "user cannot read another user's note", %{conn: conn} do
      other_user = insert(:user)
      # Insert directly via factory to avoid with_tenant role-switch leaking into sandbox
      insert(:note, user: other_user, path: "Test/Private.md", folder: "Test")

      conn = get(conn, "/api/notes/Test/Private.md")
      assert json_response(conn, 404)
    end
  end

  # ---------------------------------------------------------------------------
  # DELETE /notes/:path
  # ---------------------------------------------------------------------------

  describe "GET /api/notes/by-id/:id" do
    test "returns the note for the owner", %{conn: conn, user: user, vault: vault} do
      {:ok, note} = Engram.Notes.upsert_note(user, vault, %{path: "a.md", content: "# A"})
      conn = get(conn, ~p"/api/notes/by-id/#{note.id}")
      body = json_response(conn, 200)
      assert body["id"] == note.id
      assert body["path"] == "a.md"
    end

    test "returns 404 for non-existent id", %{conn: conn} do
      conn = get(conn, ~p"/api/notes/by-id/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404) == %{"error" => "not found"}
    end

    test "returns 400 for non-uuid id", %{conn: conn} do
      conn = get(conn, ~p"/api/notes/by-id/abc")
      assert json_response(conn, 400) == %{"error" => "invalid id"}
    end
  end

  describe "DELETE /api/notes/by-id/:id" do
    test "deletes the note", %{conn: conn, user: user, vault: vault} do
      {:ok, note} = Engram.Notes.upsert_note(user, vault, %{path: "a.md", content: "# A"})
      conn = delete(conn, ~p"/api/notes/by-id/#{note.id}")
      assert json_response(conn, 200) == %{"deleted" => true}
      assert {:error, :not_found} = Engram.Notes.get_note_by_id(user, vault, note.id)
    end

    test "returns 404 for non-existent id", %{conn: conn} do
      conn = delete(conn, ~p"/api/notes/by-id/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404) == %{"error" => "not found"}
    end

    test "returns 400 for non-uuid id", %{conn: conn} do
      conn = delete(conn, ~p"/api/notes/by-id/abc")
      assert json_response(conn, 400) == %{"error" => "invalid id"}
    end
  end

  describe "DELETE /notes/:path" do
    test "soft-deletes a note", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Test/Bye.md", content: "# Bye", mtime: 1_000.0})

      conn = delete(conn, "/api/notes/Test/Bye.md")
      assert %{"deleted" => true} = json_response(conn, 200)
    end

    test "is idempotent for nonexistent note", %{conn: conn} do
      conn = delete(conn, "/api/notes/Fake/Note.md")
      assert %{"deleted" => true} = json_response(conn, 200)
    end
  end

  # ---------------------------------------------------------------------------
  # GET /notes/changes
  # ---------------------------------------------------------------------------

  describe "GET /notes/changes" do
    test "returns changes since timestamp", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Test/Recent.md", content: "# Recent", mtime: 1_000.0})

      conn = get(conn, "/api/notes/changes?since=2020-01-01T00:00:00Z")
      assert %{"changes" => changes} = json_response(conn, 200)
      assert Enum.any?(changes, &(&1["path"] == "Test/Recent.md"))
    end

    test "change payload includes note id", %{conn: conn} do
      post_conn =
        post(conn, "/api/notes", %{path: "Test/IdShape.md", content: "# Id", mtime: 1_000.0})

      assert %{"note" => %{"id" => note_id}} = json_response(post_conn, 200)
      assert is_binary(note_id)

      conn = get(conn, "/api/notes/changes?since=2020-01-01T00:00:00Z")
      assert %{"changes" => changes} = json_response(conn, 200)

      change = Enum.find(changes, &(&1["path"] == "Test/IdShape.md"))
      assert change["id"] == note_id
      assert is_binary(change["id"])
    end

    test "includes deleted notes with deleted=true flag", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Test/Deleted.md", content: "# Del", mtime: 1_000.0})
      delete(conn, "/api/notes/Test/Deleted.md")

      conn = get(conn, "/api/notes/changes?since=2020-01-01T00:00:00Z")
      assert %{"changes" => changes} = json_response(conn, 200)

      deleted = Enum.find(changes, &(&1["path"] == "Test/Deleted.md"))
      assert deleted["deleted"] == true
    end

    test "returns empty list for future timestamp", %{conn: conn} do
      conn = get(conn, "/api/notes/changes?since=2099-01-01T00:00:00Z")
      assert %{"changes" => []} = json_response(conn, 200)
    end

    test "returns 400 for invalid timestamp", %{conn: conn} do
      conn = get(conn, "/api/notes/changes?since=not-a-date")
      assert json_response(conn, 400)
    end

    test "returns 400 when since param is missing", %{conn: conn} do
      conn = get(conn, "/api/notes/changes")
      assert json_response(conn, 400)
    end
  end

  # Pricing v2 §G — server-side notes_cap enforcement
  describe "POST /notes — notes_cap enforcement (pricing v2 §G)" do
    test "returns 402 when user is at notes_cap", %{conn: conn, user: user} do
      # Lower the cap so the test doesn't need to insert 10k notes
      insert(:user_limit_override, user: user, key: "notes_cap", value: %{"v" => 2})

      post(conn, "/api/notes", %{path: "A.md", content: "# A", mtime: 1.0})
      post(conn, "/api/notes", %{path: "B.md", content: "# B", mtime: 2.0})

      conn3 = post(conn, "/api/notes", %{path: "C.md", content: "# C", mtime: 3.0})

      body = json_response(conn3, 402)
      assert body["error"] == "limit_exceeded"
      assert body["reason"] == "notes_cap_exceeded"
      assert body["limit_key"] == "notes_cap"
      assert body["limit"] == 2
      assert body["current"] == 2
    end

    test "permits updates to existing notes after cap is hit", %{conn: conn, user: user} do
      insert(:user_limit_override, user: user, key: "notes_cap", value: %{"v" => 1})

      post(conn, "/api/notes", %{path: "A.md", content: "# A v1", mtime: 1.0})

      # Updating A is fine — only NEW notes are gated
      conn2 = post(conn, "/api/notes", %{path: "A.md", content: "# A v2", mtime: 2.0})
      assert %{"note" => _} = json_response(conn2, 200)
    end
  end

  # ---------------------------------------------------------------------------
  # POST /notes/rename
  # ---------------------------------------------------------------------------

  describe "POST /notes/rename" do
    test "returns 409 when target path exists", %{conn: conn} do
      post(conn, "/api/notes", %{path: "a.md", content: "# A", mtime: 1_000.0})
      post(conn, "/api/notes", %{path: "b.md", content: "# B", mtime: 1_000.0})

      conn2 = post(conn, "/api/notes/rename", %{old_path: "a.md", new_path: "b.md"})
      assert json_response(conn2, 409) == %{"error" => "conflict"}

      # Original still readable
      conn3 = get(conn, "/api/notes/a.md")
      assert %{"path" => "a.md"} = json_response(conn3, 200)
    end

    test "returns 404 when source path does not exist", %{conn: conn} do
      conn2 = post(conn, "/api/notes/rename", %{old_path: "missing.md", new_path: "new.md"})
      assert json_response(conn2, 404) == %{"error" => "not found"}
    end
  end

  # Free-tier launch §4.5 — standardized 402 shape via LimitResponse.halt/5
  describe "POST /api/notes — Free tier notes_cap exceeded" do
    setup %{conn: conn} do
      user =
        insert(:user, free_tier_accepted_at: DateTime.utc_now(), suspended_at: nil)

      _vault = insert(:vault, user: user, is_default: true)
      {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "ft-test-key")
      grant_api_write!(user)
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)

      # Fast-set the maintained meter to the Free-tier default cap (10_000)
      # instead of inserting 10k real notes. Limit enforcement reads
      # UsageMeters.notes_count/1, so this is the only state the resolver
      # cares about for the 402 branch.
      :ok = Engram.UsageMeters.inc_notes_count(user.id, 10_000)

      authed = put_req_header(conn, "authorization", "Bearer #{api_key}")
      %{conn: authed, user: user}
    end

    test "returns standardized 402 shape", %{conn: conn} do
      payload = %{"path" => "new.md", "content" => "x", "mtime" => 1_000.0}
      conn = post(conn, ~p"/api/notes", payload)
      body = json_response(conn, 402)
      assert body["error"] == "limit_exceeded"
      assert body["reason"] == "notes_cap_exceeded"
      assert body["tier"] == "free"
      assert body["limit_key"] == "notes_cap"
      assert body["limit"] == 10_000
      assert body["current"] == 10_000
      assert body["upgrade_url"] =~ "/settings/billing"
    end
  end

  # Free-tier launch §5.2 — ex-Pro user reverted to Free with notes > cap.
  # The resolver MUST gate writes that create new notes only. Reads, updates,
  # and deletes stay open so over-limit users can prune below the cap without
  # being held hostage. This pins behavior against accidental future
  # tightening of the resolver to apply 402 across all verbs.
  describe "ex-Pro user reverted to Free with notes > limit (§5.2)" do
    setup %{conn: conn} do
      user =
        insert(:user, free_tier_accepted_at: DateTime.utc_now(), suspended_at: nil)

      vault = insert(:vault, user: user, is_default: true)
      {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "ex-pro-test-key")
      grant_api_write!(user)
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)

      # Simulate a user well over the Free-tier 10_000-note cap (e.g. they
      # were Pro, hit 12k notes, then subscription.canceled flipped them
      # back to Free). The resolver reads UsageMeters.notes_count/1, so
      # fast-setting the meter is enough — we don't need to materialize
      # 12k Note rows.
      :ok = Engram.UsageMeters.inc_notes_count(user.id, 12_000)

      authed = put_req_header(conn, "authorization", "Bearer #{api_key}")
      %{conn: authed, user: user, vault: vault}
    end

    test "GET /api/notes/changes still lists changes (read allowed)", %{conn: conn} do
      conn = get(conn, ~p"/api/notes/changes?since=2020-01-01T00:00:00Z")
      assert %{"changes" => _} = json_response(conn, 200)
    end

    test "GET /api/notes/*path still reads an existing note (read allowed)",
         %{conn: conn, user: user, vault: vault} do
      _note = Engram.Fixtures.insert_note!(user, vault, %{path: "Existing.md"})

      conn = get(conn, ~p"/api/notes/Existing.md")
      body = json_response(conn, 200)
      assert body["path"] == "Existing.md"
    end

    test "POST /api/notes for a NEW path → 402 with notes_cap_exceeded",
         %{conn: conn} do
      conn =
        post(conn, ~p"/api/notes", %{"path" => "brand-new.md", "content" => "x", "mtime" => 1.0})

      body = json_response(conn, 402)
      assert body["reason"] == "notes_cap_exceeded"
      assert body["tier"] == "free"
    end

    test "POST /api/notes for an EXISTING path → 200 (update allowed)",
         %{conn: conn, user: user, vault: vault} do
      _note = Engram.Fixtures.insert_note!(user, vault, %{path: "Editable.md"})

      conn =
        post(conn, ~p"/api/notes", %{
          "path" => "Editable.md",
          "content" => "# edited",
          "mtime" => 2_000.0
        })

      assert %{"note" => _} = json_response(conn, 200)
    end

    test "DELETE /api/notes/*path → 200 (delete allowed for pruning below cap)",
         %{conn: conn, user: user, vault: vault} do
      _note = Engram.Fixtures.insert_note!(user, vault, %{path: "Prunable.md"})

      conn = delete(conn, ~p"/api/notes/Prunable.md")
      assert %{"deleted" => true} = json_response(conn, 200)
    end
  end
end
