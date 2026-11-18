defmodule Engram.MCP.HandlersMovedPathsTest do
  # Staging table B row 4: with the S5 write stop on, a folder rename writes
  # ONE folder row and the notes under it keep their old stored path. Every
  # MCP answer must print the path the note is SHOWN at (its folder row plus
  # its name), never the stored one, or an AI client writes back to a path
  # that no longer exists and mints a duplicate.
  use Engram.DataCase, async: false

  import Engram.FieldCatalogHelpers
  import Mox

  alias Engram.{Crypto, FolderRows, Folders, Notes, QdrantStub, Repo, ServiceConfig}
  alias Engram.Folders.Rows
  alias Engram.MCP.Handlers

  setup :verify_on_exit!

  setup do
    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)

    # Indexed (its tag rows too), so a tag filter can find it.
    note = write_indexed!(user, vault, "R4/n1.md", "---\ntags: [moved]\n---\nquixotic body")

    folder = Repo.with_tenant!(user.id, fn -> Rows.ids_by_path(user, vault.id, ["R4"]) end)
    FolderRows.move_uncascaded!(user, folder["R4"], "R4mcp")

    %{user: user, vault: vault, note: note}
  end

  describe "get_notes" do
    test "prints the shown path, not the stored one", %{user: u, vault: v} do
      assert {:ok, text, %{"notes" => [payload]}} =
               Handlers.handle("get_notes", u, v, %{"paths" => ["R4mcp/n1.md"]})

      assert text =~ "**Path:** R4mcp/n1.md"
      assert text =~ "**Folder:** R4mcp"
      refute text =~ "R4/n1.md"
      assert payload["path"] == "R4mcp/n1.md"
      assert payload["folder"] == "R4mcp"
    end

    test "outline prints the shown path", %{user: u, vault: v} do
      assert {:ok, text, %{"notes" => [payload]}} =
               Handlers.handle("get_notes", u, v, %{
                 "paths" => ["R4mcp/n1.md"],
                 "outline" => true
               })

      assert text =~ "**Path:** R4mcp/n1.md"
      assert payload["path"] == "R4mcp/n1.md"
    end
  end

  describe "search_notes" do
    test "recent lists the shown path", %{user: u, vault: v} do
      assert {:ok, text, %{"results" => [r]}} = Handlers.handle("search_notes", u, v, %{})
      assert text =~ "- R4mcp/n1.md"
      assert r["source_path"] == "R4mcp/n1.md"
    end

    test "a tag filter lists the shown path", %{user: u, vault: v} do
      assert {:ok, text, %{"results" => [r]}} =
               Handlers.handle("search_notes", u, v, %{"tags" => ["moved"]})

      assert text =~ "- R4mcp/n1.md"
      assert r["source_path"] == "R4mcp/n1.md"
    end

    test "a query hit prints the shown path", %{user: u, vault: v, note: note} do
      bypass = Bypass.open()
      Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
      on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)
      QdrantStub.stub_retrieve(bypass)
      stub(Engram.MockEmbedder, :embed_texts, fn _, _ -> {:ok, [List.duplicate(0.1, 3)]} end)

      point = %{
        "id" =>
          Engram.Fixtures.insert_chunk!(u, note, Ecto.UUID.generate(), text: "quixotic body"),
        "score" => 0.8
      }

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query/batch", fn c ->
        c
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(QdrantStub.batch(c, %{"result" => [point]})))
      end)

      assert {:ok, text, %{"results" => [r]}} =
               Handlers.handle("search_notes", u, v, %{"query" => "quixotic", "diversity" => 0.0})

      assert r["source_path"] == "R4mcp/n1.md"
      refute text =~ "R4/n1.md"
    end
  end

  defp live_count(vault) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*)::int FROM notes WHERE vault_id = $1 AND kind = 'note' " <>
          "AND deleted_at IS NULL",
        [Ecto.UUID.dump!(vault.id)]
      )

    n
  end

  describe "rename_note" do
    test "renames the moved note from its shown path", %{user: u, vault: v, note: note} do
      assert {:ok, text, %{"new_path" => "R4mcp/n2.md"}} =
               Handlers.handle("rename_note", u, v, %{
                 "old_path" => "R4mcp/n1.md",
                 "new_path" => "R4mcp/n2.md"
               })

      assert text =~ "R4mcp/n1.md -> R4mcp/n2.md"

      assert {:ok, got, %{"notes" => [%{"path" => "R4mcp/n2.md"}]}} =
               Handlers.handle("get_notes", u, v, %{"paths" => ["R4mcp/n2.md"]})

      assert got =~ "quixotic body"
      assert {:ok, %{id: id}} = Notes.get_note(u, v, "R4mcp/n2.md")
      assert id == note.id
      assert {:error, :not_found} = Notes.get_note(u, v, "R4mcp/n1.md")
      assert {:error, :not_found} = Notes.get_note(u, v, "R4/n1.md")
      assert live_count(v) == 1

      # The rename's tombstone names the path the note was shown at.
      {:ok, %{changes: changes}} = Notes.list_changes_by_seq(u, v, 0, limit: 500)
      paths = for c <- changes, c.id == note.id, do: c.path
      refute "R4/n1.md" in paths
    end
  end

  describe "list_folder" do
    test "lists the moved note under the moved folder", %{user: u, vault: v} do
      assert {:ok, text, %{"notes" => [%{"path" => "R4mcp/n1.md"}]}} =
               Handlers.handle("list_folder", u, v, %{"folder" => "R4mcp"})

      assert text =~ "| R4mcp/n1.md |"
      refute text =~ "R4/n1.md"

      assert {:ok, _, %{"notes" => []}} =
               Handlers.handle("list_folder", u, v, %{"folder" => "R4"})

      assert {:ok, _, %{"folders" => folders}} = Handlers.handle("list_folder", u, v, %{})
      assert Enum.map(folders, & &1["folder"]) == ["R4mcp"]
    end
  end

  # Mixed window: a 0.89.0 node renames the folder with the S5 write stop on
  # (`Folders.rename/5`, the folder writer this branch shares unchanged with
  # release-v0.89.0), and a release D node answers the MCP reads.
  test "a 0.89.0 write-stop rename: D's MCP reads print the shown path", %{user: u} do
    ServiceConfig.put_override(:folder_ops, true)
    v = insert(:vault, user: u)
    {:ok, _} = Notes.upsert_note(u, v, %{"path" => "W/n.md", "content" => "w"}, actor: "api")
    {:ok, _} = Folders.rename(u, v, "W", "W2")

    %{rows: [[false]]} =
      Repo.query!("SELECT notes_cascaded FROM folders WHERE vault_id = $1", [
        Ecto.UUID.dump!(v.id)
      ])

    assert {:ok, text, %{"notes" => [%{"path" => "W2/n.md"}]}} =
             Handlers.handle("get_notes", u, v, %{"paths" => ["W2/n.md"]})

    assert text =~ "**Path:** W2/n.md"

    assert {:ok, _, %{"results" => [%{"source_path" => "W2/n.md"}]}} =
             Handlers.handle("search_notes", u, v, %{})

    assert {:ok, _, %{"notes" => [%{"path" => "W2/n.md"}]}} =
             Handlers.handle("list_folder", u, v, %{"folder" => "W2"})
  end
end
