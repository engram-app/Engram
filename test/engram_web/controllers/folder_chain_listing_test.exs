defmodule EngramWeb.FolderChainListingTest do
  # O(1) folder rename plan, Gap A (Engram#2523): `/sync/manifest` and
  # `/vault/tree` read through `Engram.Notes.Location`. A note under a folder
  # moved without a cascade (S5's write: one folder row, the notes keep their
  # old stored path) is listed where its folder row puts it; every other
  # note at its stored path, exactly as before. Both listings gain additive
  # `folder_id`/`name` per note and the folder rows (`folders` in the
  # manifest, `folder_tree` in the tree) while the S3 name reads are on.
  #
  # async: false: the name-reads gate is a node-wide cache entry.
  use EngramWeb.ConnCase, async: false

  alias Engram.{FolderRows, Notes, QueryRecorder, Repo, ServiceConfig}
  alias Engram.Folders.Rows

  setup :authed_api_conn

  setup %{user: user, vault: vault} do
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)

    ids =
      for path <- ["A/B/x.md", "A/B/C/y.md", "A/b/Ünï 日本.md", "top.md"], into: %{} do
        {:ok, n} =
          Notes.upsert_note(user, vault, %{"path" => path, "content" => "# #{path}"},
            actor: "api"
          )

        {path, n.id}
      end

    Engram.Cache.clear_local(:note_name)
    on_exit(fn -> Engram.Cache.clear_local(:note_name) end)
    %{user: user, ids: ids}
  end

  defp folder(user, vault, path),
    do: Repo.with_tenant!(user.id, fn -> Rows.ids_by_path(user, vault.id, [path]) end)[path]

  defp manifest(conn), do: conn |> get(~p"/api/sync/manifest") |> json_response(200)
  defp tree(conn), do: conn |> get(~p"/api/vault/tree") |> json_response(200)

  defp by_id(entries), do: Map.new(entries, &{&1["id"], &1})

  defp names_off! do
    ServiceConfig.put_override(:name_reads_ledger, :read)
    Engram.Cache.clear_local(:note_name)
    refute Notes.Location.on?()
  end

  describe "while writers cascade (no moved folder)" do
    test "both listings: stored paths, plus folder_id and name agreeing with them", %{
      conn: conn,
      user: u,
      vault: v,
      ids: ids
    } do
      b = folder(u, v, "A/B")
      c = folder(u, v, "A/B/C")
      lower = folder(u, v, "A/b")

      expected = %{
        ids["A/B/x.md"] => {"A/B/x.md", b, "x.md"},
        ids["A/B/C/y.md"] => {"A/B/C/y.md", c, "y.md"},
        ids["A/b/Ünï 日本.md"] => {"A/b/Ünï 日本.md", lower, "Ünï 日本.md"},
        ids["top.md"] => {"top.md", nil, "top.md"}
      }

      m = manifest(conn)
      t = tree(conn)

      for body <- [m["notes"], t["notes"]], {id, n} <- by_id(body) do
        assert {n["path"], n["folder_id"], n["name"]} == expected[id]
      end

      folders = Enum.sort_by(m["folders"], & &1["id"])
      assert folders == Enum.sort_by(t["folder_tree"], & &1["id"])

      assert %{"id" => ^c, "parent_id" => ^b, "name" => "C"} =
               Enum.find(folders, &(&1["id"] == c))

      # The tree's counts shape is unchanged.
      assert Enum.all?(t["folders"], &Map.has_key?(&1, "count"))
    end

    test "a drift row: stored path, and the folder_id its path names", %{
      conn: conn,
      user: u,
      vault: v,
      ids: ids
    } do
      other = folder(u, v, "A/b")

      Repo.query!("UPDATE notes SET folder_ref_id = $2 WHERE id = $1", [
        Ecto.UUID.dump!(ids["A/B/x.md"]),
        Ecto.UUID.dump!(other)
      ])

      for body <- [manifest(conn), tree(conn)] do
        n = by_id(body["notes"])[ids["A/B/x.md"]]
        assert {n["path"], n["folder_id"]} == {"A/B/x.md", folder(u, v, "A/B")}
      end
    end

    test "no per-note name is read or decrypted", %{conn: conn} do
      {_, queries} = QueryRecorder.record(fn -> {manifest(conn), tree(conn)} end)
      me = self()
      notes_reads = for %{sql: s, pid: ^me} <- queries, s =~ ~s(FROM "notes"), do: s
      assert notes_reads != []
      refute Enum.any?(notes_reads, &(&1 =~ ~s(n0."name_ciphertext")))
      # One probe of the empty moved-folder index per listing, nothing else new.
      assert [_, _] = for(%{sql: s, pid: ^me} <- queries, s =~ "notes_cascaded", do: s)
    end

    test "names off: stored paths and no new fields", %{conn: conn, ids: ids} do
      names_off!()
      m = manifest(conn)
      t = tree(conn)

      refute Map.has_key?(m, "folders")
      refute Map.has_key?(t, "folder_tree")

      for body <- [m["notes"], t["notes"]], n <- body do
        refute Map.has_key?(n, "folder_id")
        refute Map.has_key?(n, "name")
      end

      assert by_id(m["notes"])[ids["A/B/x.md"]]["path"] == "A/B/x.md"
    end
  end

  describe "a folder moved without a cascade (S5 write shape)" do
    setup %{user: u, vault: v} do
      b = folder(u, v, "A/B")
      FolderRows.move_uncascaded!(u, b, "Z")
      %{b: b}
    end

    test "both listings serve its notes where the folder row puts them", %{
      conn: conn,
      user: u,
      vault: v,
      ids: ids,
      b: b
    } do
      c = folder(u, v, "A/Z/C")

      for body <- [manifest(conn), tree(conn)] do
        notes = by_id(body["notes"])

        assert {notes[ids["A/B/x.md"]]["path"], notes[ids["A/B/x.md"]]["folder_id"]} ==
                 {"A/Z/x.md", b}

        assert {notes[ids["A/B/C/y.md"]]["path"], notes[ids["A/B/C/y.md"]]["folder_id"]} ==
                 {"A/Z/C/y.md", c}

        # Untouched notes keep their stored path.
        assert notes[ids["top.md"]]["path"] == "top.md"
        assert notes[ids["A/b/Ünï 日本.md"]]["path"] == "A/b/Ünï 日本.md"
      end
    end

    test "a row the previous release rewrote (stale name stamp) keeps its stored path", %{
      conn: conn,
      ids: ids
    } do
      # N-1 rewrote the path (a fresh path nonce) without the name.
      Repo.query!("UPDATE notes SET name_stamp = '\\x00' WHERE id = $1", [
        Ecto.UUID.dump!(ids["A/B/x.md"])
      ])

      for body <- [manifest(conn), tree(conn)] do
        notes = by_id(body["notes"])
        assert notes[ids["A/B/x.md"]]["path"] == "A/B/x.md"
        assert notes[ids["A/B/C/y.md"]]["path"] == "A/Z/C/y.md"
      end
    end

    test "a trashed note under it stays out of both listings", %{conn: conn, ids: ids} do
      Repo.query!("UPDATE notes SET deleted_at = now() WHERE id = $1", [
        Ecto.UUID.dump!(ids["A/B/C/y.md"])
      ])

      for body <- [manifest(conn), tree(conn)] do
        refute Map.has_key?(by_id(body["notes"]), ids["A/B/C/y.md"])
      end
    end

    test "names off: stored paths (0.86.0 behaviour)", %{conn: conn, ids: ids} do
      names_off!()

      for body <- [manifest(conn), tree(conn)] do
        assert by_id(body["notes"])[ids["A/B/x.md"]]["path"] == "A/B/x.md"
      end
    end
  end
end
