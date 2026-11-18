defmodule Engram.Folders.NestedCollisionTest do
  # A folder rename or batch move whose only collision is BELOW the target
  # (S/sub onto an existing D/sub). The gate checks the target itself, so these
  # reach the cascade: a landed MARKER merges into the destination's marker
  # (#2468), a landed NOTE is a conflict, and neither ever raises out of the
  # transaction (e2e run 44283703701: the raise crashed the crdt channel).
  # The crdt channel caller is covered in crdt_channel_folder_op_test.exs.
  use EngramWeb.ConnCase, async: false

  alias Engram.{Folders, Notes}
  alias Engram.MCP.Handlers

  setup :authed_api_conn

  setup %{user: user} do
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    on_exit(fn -> Application.delete_env(:engram, :checkpoint_interleave_hook) end)
    %{user: user}
  end

  defp markers(u, v),
    do: u |> Notes.list_folder_markers(v) |> Enum.map(& &1.folder) |> Enum.sort()

  defp note!(u, v, path) do
    {:ok, _} = Notes.upsert_note(u, v, %{"path" => path, "content" => "# #{path}"}, actor: "api")
  end

  defp live?(u, v, path), do: match?({:ok, _}, Notes.get_note(u, v, path))

  defp merge_case(u, v) do
    {:ok, _} = Folders.create_markers(u, v, ["S/sub", "D/sub"])
    note!(u, v, "S/sub/n.md")
  end

  defp note_case(u, v) do
    note!(u, v, "S/sub/x.md")
    note!(u, v, "D/sub/x.md")
  end

  defp assert_merged(u, v) do
    assert markers(u, v) == ["D/sub"]
    assert live?(u, v, "D/sub/n.md")
    refute live?(u, v, "S/sub/n.md")
  end

  defp assert_untouched(u, v) do
    assert live?(u, v, "S/sub/x.md")
    assert live?(u, v, "D/sub/x.md")
  end

  describe "a landed marker merges" do
    test "Folders.rename", %{user: u, vault: v} do
      merge_case(u, v)
      assert {:ok, _} = Folders.rename(u, v, "S", "D")
      assert_merged(u, v)
    end

    test "REST rename", %{conn: conn, user: u, vault: v} do
      merge_case(u, v)

      conn
      |> post(~p"/api/folders/rename", %{"old_path" => "S", "new_path" => "D"})
      |> json_response(200)

      assert_merged(u, v)
    end

    test "MCP rename_folder", %{user: u, vault: v} do
      merge_case(u, v)

      assert {:ok, _, _} =
               Handlers.handle("rename_folder", u, v, %{"old_folder" => "S", "new_folder" => "D"})

      assert_merged(u, v)
    end

    test "REST batch-move", %{conn: conn, user: u, vault: v} do
      {:ok, %{folders: [s | _]}} = Notes.create_folder_markers(u, v, ["S", "S/sub", "Dst/S/sub"])
      note!(u, v, "S/sub/n.md")

      conn
      |> put_req_header("x-idempotency-key", Ecto.UUID.generate())
      |> post(~p"/api/folders/batch-move", %{"ids" => [s.id], "target_parent" => "Dst"})
      |> json_response(200)

      assert markers(u, v) == ["Dst/S", "Dst/S/sub"]
      assert live?(u, v, "Dst/S/sub/n.md")
    end
  end

  describe "a landed note is a conflict and nothing moves" do
    test "REST rename is a 409", %{conn: conn, user: u, vault: v} do
      note_case(u, v)

      conn
      |> post(~p"/api/folders/rename", %{"old_path" => "S", "new_path" => "D"})
      |> json_response(409)

      assert_untouched(u, v)
    end

    test "MCP rename_folder is a path_conflict", %{user: u, vault: v} do
      note_case(u, v)

      assert {:error, {:path_conflict, _}} =
               Handlers.handle("rename_folder", u, v, %{"old_folder" => "S", "new_folder" => "D"})

      assert_untouched(u, v)
    end

    test "REST batch-move is a 409", %{conn: conn, user: u, vault: v} do
      {:ok, %{folders: [s]}} = Notes.create_folder_markers(u, v, ["S"])
      note!(u, v, "S/sub/x.md")
      note!(u, v, "Dst/S/sub/x.md")

      conn
      |> put_req_header("x-idempotency-key", Ecto.UUID.generate())
      |> post(~p"/api/folders/batch-move", %{"ids" => [s.id], "target_parent" => "Dst"})
      |> json_response(409)

      assert live?(u, v, "S/sub/x.md")
      assert live?(u, v, "Dst/S/sub/x.md")
    end
  end

  # The race backstop in `Folders.atomic/2`. The cascade's checks leave no
  # natural way to reach it, so the hook raises from inside the transaction.
  describe "a unique violation raised inside the transaction" do
    defp raise_at_seal(constraint) do
      Application.put_env(:engram, :checkpoint_interleave_hook, fn
        :folder_rename_seal ->
          raise %Postgrex.Error{
            postgres: %{
              code: :unique_violation,
              pg_code: "23505",
              constraint: constraint,
              severity: "ERROR",
              message: "dup"
            }
          }

        _ ->
          :ok
      end)
    end

    test "on a path or marker index is a conflict", %{user: u, vault: v} do
      note!(u, v, "S/a.md")
      raise_at_seal("notes_folder_marker")
      assert {:error, :conflict} = Folders.rename(u, v, "S", "D")
      assert live?(u, v, "S/a.md")
    end

    test "on any other index is re-raised", %{user: u, vault: v} do
      note!(u, v, "S/a.md")
      raise_at_seal("folders_live_name")

      assert_raise Postgrex.Error, fn -> Folders.rename(u, v, "S", "D") end
    end
  end
end
