defmodule EngramWeb.MarkerStopSurfacesTest do
  # S6 step 4, phase 2 (#2649 review, M3): every folder surface with markers
  # stopped (`Engram.Folders.MarkerStop` on). REST, MCP and the plugin wire
  # each create, rename or move, and delete an EMPTY folder, which with the
  # stop on is a bare explicit folder row and nothing else; no marker row is
  # ever written, and the explicit listing follows each step.
  use EngramWeb.ConnCase, async: false

  alias Engram.{Folders, Notes, Repo}
  alias Engram.Folders.{Rows, Wire}
  alias Engram.MCP.Handlers

  setup :authed_api_conn

  setup %{user: user} do
    Engram.ServiceConfig.put_override(:marker_stop_floors, :assume)
    Engram.ServiceConfig.put_override(:folder_ops, true)
    assert Engram.Folders.MarkerStop.on?()
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    %{user: user}
  end

  defp markers(vault) do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM notes WHERE vault_id = $1 AND kind = 'folder'", [
        Ecto.UUID.dump!(vault.id)
      ])

    n
  end

  defp explicit(user, vault), do: elem(Notes.list_explicit_folders(user, vault), 1)

  # One surface's create / rename / delete of an empty folder.
  defp surface(:rest, conn, _user, _vault) do
    %{
      create: fn name -> conn |> post(~p"/api/folders", %{"folder" => name}) |> response(201) end,
      rename: fn old, new ->
        conn
        |> post(~p"/api/folders/rename", %{"old_path" => old, "new_path" => new})
        |> json_response(200)
      end,
      delete: fn name -> conn |> delete("/api/folders/#{name}") |> response(204) end
    }
  end

  defp surface(:mcp, _conn, user, vault) do
    ok = fn result -> assert {:ok, _, _} = result end

    %{
      create: fn name ->
        ok.(Handlers.handle("create_folder", user, vault, %{"folder" => name}))
      end,
      rename: fn old, new ->
        ok.(
          Handlers.handle("rename_folder", user, vault, %{
            "old_folder" => old,
            "new_folder" => new
          })
        )
      end,
      delete: fn name ->
        ok.(Handlers.handle("delete_folder", user, vault, %{"folder" => name}))
      end
    }
  end

  defp surface(:wire, conn, user, vault) do
    id_of = fn name ->
      Repo.with_tenant!(user.id, fn ->
        Rows.ids_by_path(user, vault.id, [name])[name]
      end)
    end

    %{
      create: fn name ->
        assert {:ok, %{folder_id: _}} =
                 Wire.apply_op(user, vault, %{"op" => "create", "name" => name}, "dev")
      end,
      rename: fn old, new ->
        assert {:ok, _} =
                 Wire.apply_op(
                   user,
                   vault,
                   %{"op" => "move", "folder_id" => id_of.(old), "name" => new},
                   "dev"
                 )
      end,
      # The plugin deletes a folder by path (REST) even with the wire on.
      delete: surface(:rest, conn, user, vault).delete
    }
  end

  for kind <- [:rest, :mcp, :wire] do
    test "#{kind}: create, rename and delete an empty folder with no marker", ctx do
      %{conn: conn, user: u, vault: v} = ctx
      s = surface(unquote(kind), conn, u, v)

      s.create.("Empty")
      assert explicit(u, v) == ["Empty"]

      s.rename.("Empty", "Renamed")
      assert explicit(u, v) == ["Renamed"]

      s.delete.("Renamed")
      assert explicit(u, v) == []
      assert markers(v) == 0
    end
  end

  test "REST: GET /api/folders lists an empty folder with its row id", %{
    conn: conn,
    user: u,
    vault: v
  } do
    conn |> post(~p"/api/folders", %{"folder" => "E"}) |> response(201)
    id = Repo.with_tenant!(u.id, fn -> Rows.ids_by_path(u, v.id, ["E"])["E"] end)

    body = conn |> get(~p"/api/folders") |> json_response(200)
    assert Enum.find(body["folders"], &(&1["name"] == "E"))["id"] == id
    assert markers(v) == 0
  end

  test "REST: a batch delete by id, then its undo, brings the folder back", ctx do
    %{conn: conn, user: u, vault: v} = ctx
    conn |> post(~p"/api/folders", %{"folder" => "B"}) |> response(201)
    id = Repo.with_tenant!(u.id, fn -> Rows.ids_by_path(u, v.id, ["B"])["B"] end)
    op = Ecto.UUID.generate()

    assert {:ok, _} = Folders.batch_delete(u, v, [id], op_id: op)
    assert explicit(u, v) == []
    assert {:ok, _} = Folders.restore_op(u, v, op)
    assert explicit(u, v) == ["B"]
  end

  test "an undo that merges into a live folder moves the seq and keeps it explicit", ctx do
    %{user: u, vault: v} = ctx
    {:ok, _} = Folders.create_markers(u, v, ["M"])
    op = Ecto.UUID.generate()
    {:ok, _} = Folders.delete(u, v, "M", recursive: true, op_id: op)
    {:ok, _} = Notes.upsert_note(u, v, %{"path" => "M/n.md", "content" => "x"}, actor: "api")
    before = Engram.Vaults.current_seq(u.id, v.id)

    assert {:ok, _} = Folders.restore_op(u, v, op)
    assert "M" in explicit(u, v)
    assert Engram.Vaults.current_seq(u.id, v.id) > before
  end

  test "MCP list_folder shows an empty explicit folder", %{user: u, vault: v} do
    {:ok, _} = Folders.create_markers(u, v, ["L"])
    assert {:ok, text, _} = Handlers.handle("list_folder", u, v, %{"folder" => ""})
    assert text =~ "L"
  end
end
