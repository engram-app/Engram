defmodule Engram.IndexingDeleteByPointIdTest do
  @moduledoc """
  A note's Qdrant points must be deleted by their point IDs, not only by the
  note's CURRENT `path_hmac`.

  The leak this closes: a rename moves `notes.path_hmac` from A to B while the
  points are still tagged A (the repath/embed job is debounced 3-300s). Deleting
  the note in that window issued a delete filtered on B, matched nothing, then
  dropped the chunk rows — stranding the A-tagged points with no row left
  anywhere that names them.
  """
  use Engram.DataCase, async: false

  alias Engram.Indexing
  alias Engram.Notes.Chunk
  alias Engram.Repo

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    user = insert(:user)
    vault = insert(:vault, user: user)
    %{bypass: bypass, user: user, vault: vault}
  end

  defp capture_deletes(bypass) do
    test_pid = self()

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      if String.ends_with?(conn.request_path, "/points/delete") do
        send(test_pid, {:qdrant_delete, Jason.decode!(body)})
      end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true}))
    end)
  end

  defp collect_deletes(acc \\ []) do
    receive do
      {:qdrant_delete, body} -> collect_deletes([body | acc])
    after
      0 -> acc
    end
  end

  test "delete_note_index deletes the note's points by id even when path_hmac drifted", %{
    bypass: bypass,
    user: user,
    vault: vault
  } do
    capture_deletes(bypass)

    persisted = insert(:note, user: user, vault: vault)
    note_id = persisted.id
    point_a = Ecto.UUID.generate()
    point_b = Ecto.UUID.generate()

    for {pid, pos} <- [{point_a, 0}, {point_b, 1}] do
      Repo.insert!(
        %Chunk{
          note_id: note_id,
          user_id: user.id,
          vault_id: vault.id,
          position: pos,
          char_start: 0,
          char_end: 10,
          qdrant_point_id: pid
        },
        skip_tenant_check: true
      )
    end

    # `path_hmac` here is the note's CURRENT (post-rename) value; the points in
    # Qdrant are still filed under the pre-rename one.
    note = %{
      id: note_id,
      user_id: user.id,
      vault_id: vault.id,
      path_hmac: :crypto.strong_rand_bytes(32)
    }

    assert :ok = Indexing.delete_note_index(note)

    bodies = collect_deletes()
    deleted_ids = bodies |> Enum.flat_map(&Map.get(&1, "points", [])) |> MapSet.new()

    assert MapSet.member?(deleted_ids, point_a)
    assert MapSet.member?(deleted_ids, point_b)

    assert Repo.all(from(c in Chunk, where: c.note_id == ^note_id), skip_tenant_check: true) == []
  end

  test "delete_note_index still issues the path_hmac filter delete", %{
    bypass: bypass,
    user: user,
    vault: vault
  } do
    capture_deletes(bypass)

    note = %{
      id: Ecto.UUID.generate(),
      user_id: user.id,
      vault_id: vault.id,
      path_hmac: :crypto.strong_rand_bytes(32)
    }

    assert :ok = Indexing.delete_note_index(note)

    # No chunk rows exist, so the id-delete is a no-op; the filter delete is the
    # only thing that can reach points whose rows are already gone.
    assert Enum.any?(collect_deletes(), &Map.has_key?(&1, "filter"))
  end
end
