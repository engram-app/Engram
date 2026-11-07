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
end
