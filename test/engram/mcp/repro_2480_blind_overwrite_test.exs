defmodule Engram.MCP.Repro2480BlindOverwriteTest do
  # Engram#2480, mechanism C (blind overwrite from a second client).
  #
  # Two MCP clients on one account. Client 2 reads the note, client 1 runs
  # edit_note replace_section, then client 2 writes based on its OLDER read.
  # The "repro 2480" tests were red before the fix: the stale write landed with
  # no compare-and-swap and client 1's section reverted to the old text. Now
  # replacing an existing note needs a base_hash, and edit/append take one,
  # so each stale write is refused and the section survives. The guards
  # ("2480 guard") pin what must keep working.
  use EngramWeb.ConnCase, async: true

  alias Engram.MCP.Handlers
  alias Engram.Notes
  alias Engram.Notes.CrdtBridge
  alias Engram.Notes.CrdtPersistence

  @path "Plan.md"
  @v0 "# Plan\n\n## Goals\n\nold section\n\n## Notes\n\nkeep me\n"
  @mcp "new section from MCP"

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user, is_default: true)
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => @path, "content" => @v0}, actor: "api")
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    lift_api_rps_cap!(user)
    %{conn: put_req_header(conn, "authorization", "Bearer #{api_key}"), user: user, vault: vault}
  end

  defp body(user, vault), do: body_at(user, vault, @path)

  defp body_at(user, vault, path) do
    {:ok, note} = Notes.get_note(user, vault, path)
    {:ok, content} = Notes.authoritative_content(user, note)
    content
  end

  # The content_hash get_notes hands an agent for its later base_hash.
  defp read_hash(u, v, path \\ @path) do
    {:ok, _text, %{"notes" => [note]}} = Handlers.handle("get_notes", u, v, %{"paths" => [path]})
    assert is_binary(note["content_hash"])
    note["content_hash"]
  end

  # A live edit in the CRDT tail, not yet checkpointed into the row: get_notes
  # serves row + tail, so the row's own content_hash is older than the view.
  defp land_tail!(u, v, path, line) do
    {:ok, row} = Notes.get_note(u, v, path)
    {:ok, state} = Engram.Crypto.decrypt_crdt_state(row, u)
    {:ok, doc} = CrdtBridge.doc_from_state(state)
    {:ok, sv} = Yex.encode_state_vector(doc)
    text = Yex.Doc.get_text(doc, CrdtBridge.text_name())
    CrdtBridge.diff_into_text(text, Yex.Text.to_string(text) <> line)
    {:ok, upd} = Yex.encode_state_as_update(doc, sv)
    st = %{user_id: u.id, vault_id: v.id, note_id: row.id}
    _ = CrdtPersistence.update_v1(st, upd, row.id, doc)
  end

  defp assert_conflict({:error, {:version_conflict, msg}}), do: assert(msg =~ "get_notes")

  # Client 2's read, then client 1's edit_note replace_section.
  defp stale_read_then_mcp_edit(u, v) do
    stale = body(u, v)

    assert {:ok, _, _} =
             Handlers.handle("edit_note", u, v, %{
               "path" => @path,
               "mode" => "replace_section",
               "heading" => "Goals",
               "content" => "#{@mcp}\n"
             })

    assert body(u, v) =~ @mcp
    stale
  end

  defp assert_mcp_kept(u, v, how) do
    now = body(u, v)

    assert not String.contains?(now, "old section") and String.contains?(now, @mcp),
           "#{how} reverted client 1's edit_note section to the old text. Note now:\n#{now}"
  end

  test "repro 2480 C1: write_note without base_hash from a stale read is refused", %{
    user: u,
    vault: v
  } do
    stale = stale_read_then_mcp_edit(u, v)
    # Client 2 adds a line to its stale copy and writes the whole note back.
    assert_conflict(
      Handlers.handle("write_note", u, v, %{
        "path" => @path,
        "content" => stale <> "\nclient 2 line\n"
      })
    )

    assert_mcp_kept(u, v, "write_note (no base_hash)")
  end

  # Why C2 reverted: replace_section has no old_text to miss. Client 2 sends
  # the section text it read ("old section" plus its addition) as the NEW
  # content, so the server faithfully writes the old text back. Nothing in
  # that request says it was built from a stale read; only the base_hash of
  # that read can. With it, the rewrite is refused.
  test "repro 2480 C2: edit_note replace_section from a stale read is refused by base_hash", %{
    user: u,
    vault: v
  } do
    stale_hash = read_hash(u, v)
    _stale = stale_read_then_mcp_edit(u, v)

    assert_conflict(
      Handlers.handle("edit_note", u, v, %{
        "path" => @path,
        "mode" => "replace_section",
        "heading" => "Goals",
        "content" => "old section\nclient 2 addition\n",
        "base_hash" => stale_hash
      })
    )

    assert_mcp_kept(u, v, "edit_note replace_section (stale base_hash)")
  end

  test "repro 2480 C3: REST POST /notes with an API key and no base_hash is refused",
       %{conn: conn, user: u, vault: v} do
    stale = stale_read_then_mcp_edit(u, v)

    body =
      conn
      |> post("/api/notes", %{path: @path, content: stale <> "\nrest line\n", mtime: 2.0})
      |> json_response(409)

    assert body["conflict"] == true
    assert body["server_note"]["content"] =~ @mcp
    assert_mcp_kept(u, v, "POST /notes (no base_hash)")
  end

  # -- Edge cases of the base_hash rule --

  # The gate create_note and append_or_create's create-on-miss pass. A
  # concurrent create that lands between create_note's existence check and
  # its write is found by the upsert's own lookup, and must be refused there,
  # not replaced. (The sandbox runs one connection, so the gap itself cannot
  # be interleaved here; this pins the refusal the gap reaches.)
  test "2480 edge: require_base upsert refuses an existing note and creates a new one", %{
    user: u,
    vault: v
  } do
    before = body(u, v)
    opts = [actor: "mcp", require_base: true]

    assert {:error, :version_conflict, server} =
             Notes.upsert_note(u, v, %{"path" => @path, "content" => "loser\n"}, opts)

    assert server.content == before
    assert body(u, v) == before

    assert {:ok, _} =
             Notes.upsert_note(u, v, %{"path" => "Brand New.md", "content" => "a\n"}, opts)
  end

  test "2480 edge: write_note creates a new note without base_hash", %{user: u, vault: v} do
    assert {:ok, _, _} =
             Handlers.handle("write_note", u, v, %{"path" => "Fresh.md", "content" => "hi\n"})

    {:ok, note} = Notes.get_note(u, v, "Fresh.md")
    assert {:ok, "hi\n"} = Notes.authoritative_content(u, note)
  end

  test "2480 edge: write_note with the base_hash get_notes returned replaces the note", %{
    user: u,
    vault: v
  } do
    base = read_hash(u, v)

    assert {:ok, _, _} =
             Handlers.handle("write_note", u, v, %{
               "path" => @path,
               "content" => "replaced\n",
               "base_hash" => base
             })

    assert body(u, v) == "replaced\n"
  end

  test "2480 edge: write_note retried with its old base after it landed succeeds", %{
    user: u,
    vault: v
  } do
    args = %{"path" => @path, "content" => "replaced\n", "base_hash" => read_hash(u, v)}
    assert {:ok, _, _} = Handlers.handle("write_note", u, v, args)
    # The response was lost; the agent retries the same call.
    assert {:ok, _, _} = Handlers.handle("write_note", u, v, args)
    assert body(u, v) == "replaced\n"
  end

  test "2480 edge: edit_note and append_to_note with a fresh base_hash write", %{
    user: u,
    vault: v
  } do
    assert {:ok, _, _} =
             Handlers.handle("edit_note", u, v, %{
               "path" => @path,
               "mode" => "replace_text",
               "find" => "keep me",
               "replace" => "kept",
               "base_hash" => read_hash(u, v)
             })

    assert {:ok, _, _} =
             Handlers.handle("append_to_note", u, v, %{
               "path" => @path,
               "text" => "tail\n",
               "base_hash" => read_hash(u, v)
             })

    assert body(u, v) =~ "kept"
    assert body(u, v) =~ "tail"
  end

  test "2480 edge: edit_note replace_text and append_to_note with a stale base_hash refuse",
       %{user: u, vault: v} do
    stale_hash = read_hash(u, v)
    _ = stale_read_then_mcp_edit(u, v)
    before = body(u, v)

    assert_conflict(
      Handlers.handle("edit_note", u, v, %{
        "path" => @path,
        "mode" => "replace_text",
        "find" => "keep me",
        "replace" => "client 2",
        "base_hash" => stale_hash
      })
    )

    assert_conflict(
      Handlers.handle("append_to_note", u, v, %{
        "path" => @path,
        "text" => "client 2 tail\n",
        "base_hash" => stale_hash
      })
    )

    assert body(u, v) == before
  end

  test "2480 edge: REST create without base_hash and replace with a fresh one both work", %{
    conn: conn,
    user: u,
    vault: v
  } do
    conn
    |> post("/api/notes", %{path: "New.md", content: "one\n", mtime: 1.0})
    |> json_response(200)

    hash = read_hash(u, v, "New.md")

    conn
    |> post("/api/notes", %{path: "New.md", content: "two\n", mtime: 2.0, base_hash: hash})
    |> json_response(200)

    assert body_at(u, v, "New.md") == "two\n"
  end

  test "2480 edge: the Obsidian plugin (X-Plugin-Version) still pushes without base_hash", %{
    conn: conn,
    user: u,
    vault: v
  } do
    conn
    |> put_req_header("x-plugin-version", "9.0.0")
    |> post("/api/notes", %{path: @path, content: "from obsidian\n", mtime: 2.0})
    |> json_response(200)

    assert body(u, v) == "from obsidian\n"
  end

  for ua <- [
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) " <>
          "obsidian/1.12.7 Chrome/142.0.7444.265 Electron/39.8.3 Safari/537.36",
        "Obsidian/396 CFNetwork/3860.700.2 Darwin/25.6.0",
        "Dalvik/2.1.0 (Linux; U; Android 15; moto g34 5G Build/V1UGS35H.75-14-6-2-4)"
      ] do
    test "2480 edge: a pre-1.29 plugin (no version header, Obsidian UA) pushes: #{ua}", %{
      conn: conn,
      user: u,
      vault: v
    } do
      conn
      |> put_req_header("user-agent", unquote(ua))
      |> post("/api/notes", %{path: @path, content: "old plugin\n", mtime: 2.0})
      |> json_response(200)

      assert body(u, v) == "old plugin\n"
    end
  end

  test "2480 edge: a script user agent with an API key still needs base_hash", %{
    conn: conn,
    user: u,
    vault: v
  } do
    before = body(u, v)

    for ua <- ["Python-urllib/3.12", "node"] do
      conn
      |> put_req_header("user-agent", ua)
      |> post("/api/notes", %{path: @path, content: "script\n", mtime: 2.0})
      |> json_response(409)
    end

    assert body(u, v) == before
  end

  test "2480 edge: a user-token client (web app, device-flow plugin) pushes without base_hash", %{
    user: u,
    vault: v
  } do
    build_conn()
    |> authenticate(u)
    |> post("/api/notes", %{path: @path, content: "from web\n", mtime: 2.0})
    |> json_response(200)

    assert body(u, v) == "from web\n"
  end

  test "2480 guard: write_note with the stale base_hash is refused and writes nothing", %{
    user: u,
    vault: v
  } do
    stale = stale_read_then_mcp_edit(u, v)
    {:ok, base} = Notes.content_hash(u, stale)

    assert {:error, _} =
             Handlers.handle("write_note", u, v, %{
               "path" => @path,
               "content" => stale <> "\nclient 2 line\n",
               "base_hash" => base
             })

    assert_mcp_kept(u, v, "write_note (stale base_hash)")
  end

  test "2480 guard: edit_note replace_text whose old_text still matches does not clobber", %{
    user: u,
    vault: v
  } do
    _stale = stale_read_then_mcp_edit(u, v)

    assert {:ok, _, _} =
             Handlers.handle("edit_note", u, v, %{
               "path" => @path,
               "mode" => "replace_text",
               "old_text" => "keep me",
               "new_text" => "kept by client 2"
             })

    assert_mcp_kept(u, v, "edit_note replace_text (other region)")
    assert body(u, v) =~ "kept by client 2"
  end

  test "2480 guard: edit_note replace_text whose old_text was the replaced section misses", %{
    user: u,
    vault: v
  } do
    _stale = stale_read_then_mcp_edit(u, v)

    assert {:error, _} =
             Handlers.handle("edit_note", u, v, %{
               "path" => @path,
               "mode" => "replace_text",
               "old_text" => "old section",
               "new_text" => "client 2 version"
             })

    assert_mcp_kept(u, v, "edit_note replace_text (stale old_text)")
  end

  test "2480 guard: append_to_note after the edit does not clobber", %{user: u, vault: v} do
    _stale = stale_read_then_mcp_edit(u, v)

    assert {:ok, _, _} =
             Handlers.handle("append_to_note", u, v, %{"path" => @path, "text" => "appended\n"})

    assert_mcp_kept(u, v, "append_to_note")
  end

  # -- #2486 fix-forward: the ChatGPT sequence (create, then rewrite blind) --

  test "write_note's reply carries the content_hash a rewrite needs", %{user: u, vault: v} do
    assert {:ok, _, %{"content_hash" => hash}} =
             Handlers.handle("write_note", u, v, %{"path" => "Made.md", "content" => "first\n"})

    assert hash == read_hash(u, v, "Made.md")

    assert {:ok, _, %{"content_hash" => next}} =
             Handlers.handle("write_note", u, v, %{
               "path" => "Made.md",
               "content" => "second\n",
               "base_hash" => hash
             })

    assert body_at(u, v, "Made.md") == "second\n"
    assert next == read_hash(u, v, "Made.md")
  end

  test "create_note's reply carries the content_hash a rewrite needs", %{user: u, vault: v} do
    assert {:ok, _, %{"path" => path, "content_hash" => hash}} =
             Handlers.handle("create_note", u, v, %{
               "title" => "Fresh Idea",
               "content" => "draft\n",
               "suggested_folder" => "Ideas"
             })

    assert hash == read_hash(u, v, path)

    assert {:ok, _, _} =
             Handlers.handle("write_note", u, v, %{
               "path" => path,
               "content" => "final\n",
               "base_hash" => hash
             })

    assert body_at(u, v, path) == "final\n"
  end

  test "a blind rewrite's refusal names the exact retry", %{user: u, vault: v} do
    assert {:error, {:version_conflict, msg}} =
             Handlers.handle("write_note", u, v, %{"path" => @path, "content" => "x\n"})

    assert msg =~ "base_hash = "
    assert msg =~ "content_hash"
    assert msg =~ "get_notes"
    assert msg =~ "edit_note"
  end

  test "a stale base's refusal names the exact retry", %{user: u, vault: v} do
    assert {:error, {:version_conflict, msg}} =
             Handlers.handle("write_note", u, v, %{
               "path" => @path,
               "content" => "x\n",
               "base_hash" => "deadbeef"
             })

    assert msg =~ "base_hash = "
    assert msg =~ "get_notes"
    assert msg =~ "edit_note"
  end

  test "after a rewrite over a live tail edit, the reply's content_hash is get_notes'", %{
    user: u,
    vault: v
  } do
    land_tail!(u, v, @path, "LIVE\n")
    base = read_hash(u, v)

    assert {:ok, _, %{"content_hash" => hash}} =
             Handlers.handle("write_note", u, v, %{
               "path" => @path,
               "content" => body(u, v) <> "AGENT\n",
               "base_hash" => base
             })

    assert hash == read_hash(u, v)
  end

  # Re-saving unchanged content over a pending tail is a no-op: the reply's
  # content_hash must still be the one get_notes serves (not the row's older
  # one), and nothing is broadcast because nothing changed. Review of #2518.
  for {shape, seed, line} <- [
        {"plain", @v0, "LIVE\n"},
        {"frontmatter-only", "---\ntags: [a]\n---\n", "LIVE\n"},
        {"CRLF", "# A\r\n\r\nline\r\n", "LIVE\r\n"}
      ] do
    test "a no-op rewrite over a live tail edit returns get_notes' hash (#{shape})", %{
      user: u,
      vault: v
    } do
      path = "Noop.md"

      {:ok, _} =
        Notes.upsert_note(u, v, %{"path" => path, "content" => unquote(seed)}, actor: "api")

      land_tail!(u, v, path, unquote(line))
      {:ok, _, %{"notes" => [seen]}} = Handlers.handle("get_notes", u, v, %{"paths" => [path]})
      EngramWeb.Endpoint.subscribe("sync:#{u.id}:#{v.id}")

      assert {:ok, _, %{"content_hash" => hash}} =
               Handlers.handle("write_note", u, v, %{
                 "path" => path,
                 "content" => seen["content"],
                 "base_hash" => seen["content_hash"]
               })

      assert hash == read_hash(u, v, path)
      refute_receive %Phoenix.Socket.Broadcast{event: "note_changed"}, 100

      assert {:ok, _, _} =
               Handlers.handle("write_note", u, v, %{
                 "path" => path,
                 "content" => "second\n",
                 "base_hash" => hash
               })
    end
  end
end
