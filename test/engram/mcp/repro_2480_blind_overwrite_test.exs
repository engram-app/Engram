defmodule Engram.MCP.Repro2480BlindOverwriteTest do
  # Engram#2480, mechanism C (blind overwrite from a second client).
  #
  # Two MCP clients on one account. Client 2 reads the note, client 1 runs
  # edit_note replace_section, then client 2 writes based on its OLDER read.
  # Tests named "repro 2480" are RED on main by design: the write lands with
  # no compare-and-swap and client 1's section reverts to the old text. Each
  # is labelled "by design or bug" in the issue; the guards ("2480 guard")
  # pin what must keep working and pass today.
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

  defp body(user, vault) do
    {:ok, note} = Notes.get_note(user, vault, @path)
    {:ok, content} = Notes.authoritative_content(user, note)
    content
  end

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

  test "repro 2480 C1: write_note without base_hash from a stale read clobbers the edit", %{
    user: u,
    vault: v
  } do
    stale = stale_read_then_mcp_edit(u, v)
    # Client 2 adds a line to its stale copy and writes the whole note back.
    assert {:ok, _, _} =
             Handlers.handle("write_note", u, v, %{
               "path" => @path,
               "content" => stale <> "\nclient 2 line\n"
             })

    assert_mcp_kept(u, v, "write_note (no base_hash)")
  end

  test "repro 2480 C2: edit_note replace_section built from a stale read clobbers the edit", %{
    user: u,
    vault: v
  } do
    _stale = stale_read_then_mcp_edit(u, v)
    # Client 2 rewrites the same section from what it read: the old text plus
    # its own addition. No base to check it against.
    assert {:ok, _, _} =
             Handlers.handle("edit_note", u, v, %{
               "path" => @path,
               "mode" => "replace_section",
               "heading" => "Goals",
               "content" => "old section\nclient 2 addition\n"
             })

    assert_mcp_kept(u, v, "edit_note replace_section (no base_hash)")
  end

  test "repro 2480 C3: REST POST /notes without base_hash from a stale read clobbers the edit",
       %{conn: conn, user: u, vault: v} do
    stale = stale_read_then_mcp_edit(u, v)

    conn
    |> post("/api/notes", %{path: @path, content: stale <> "\nrest line\n", mtime: 2.0})
    |> json_response(200)

    assert_mcp_kept(u, v, "POST /notes (no base_hash)")
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
