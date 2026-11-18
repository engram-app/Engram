defmodule Engram.Folders.ChainNotHashTest do
  @moduledoc """
  S6 step 3, read switch (Engram#2523): the folder writers (`Rows.ensure/4`
  and its batch), the move cycle check and the folder delete fence find a
  folder by its parent chain, never by `folders.full_path_hmac`. From the
  next release a folder rename rewrites only the renamed row, so a
  descendant kept the hash of its OLD path. Each test renamed an ancestor
  and (until the column's drop, 20261118120000) planted that stale hash;
  it asserts the chain answer. Red before: each read the hash.
  """
  use Engram.DataCase, async: false

  alias Engram.Crypto
  alias Engram.Folders.Rows
  alias Engram.Notes
  alias Engram.Repo

  setup do
    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp tenant!(user, fun) do
    {:ok, result} = Repo.with_tenant(user.id, fun)
    result
  end

  # "A/B" then A renamed to C. Returns B's id.
  defp stale_descendant(%{user: u, vault: v}) do
    tenant!(u, fn ->
      {:ok, b} = Rows.ensure(u, v.id, "A/B")
      :ok = Rows.rename(u, v.id, "A", "C")
      b
    end)
  end

  test "ensure creates a folder at the path a stale hash still names", ctx do
    %{user: u, vault: v} = ctx
    b = stale_descendant(ctx)

    new = tenant!(u, fn -> Rows.ensure(u, v.id, "A/B") end)

    assert {:ok, id} = new
    refute id == b
    assert {:ok, "A/B"} = tenant!(u, fn -> Rows.path_by_id(u, v.id, id) end)
    assert {:ok, "C/B"} = tenant!(u, fn -> Rows.path_by_id(u, v.id, b) end)
  end

  test "the cycle check does not refuse a move by a stale hash", ctx do
    %{user: u, vault: v} = ctx
    _b = stale_descendant(ctx)

    # "A/B" is free on the chain (only C/B exists), so C may move under it.
    assert :ok = tenant!(u, fn -> Rows.check_move(u, v.id, "C", "A/B/X") end)
    # The chain still refuses a real cycle.
    assert {:error, :invalid_path} = tenant!(u, fn -> Rows.check_move(u, v.id, "C", "C/B/X") end)
  end

  test "the delete fence spares a note whose folder an ancestor rename moved", ctx do
    %{user: u, vault: v} = ctx

    {:ok, note} =
      Notes.upsert_note(u, v, %{"path" => "A/B/x.md", "content" => "x", "mtime" => 1.0},
        actor: "api"
      )

    {:ok, matches} = Notes.scan_folders(u, v, ["A/B"])
    assert note.id in Enum.map(matches, & &1.id)

    # After the scan: A renamed to C in one row.
    :ok = tenant!(u, fn -> Rows.rename(u, v.id, "A", "C") end)

    assert {:ok, %{notes: 0}} = Notes.delete_scanned(u, v, matches)
    assert %{deleted_at: nil} = Repo.with_tenant!(u.id, fn -> Repo.get!(Notes.Note, note.id) end)
  end

  # S6 step 3 write stop: a rename writes the renamed row only. Red before:
  # every descendant's `full_path_hmac` (and `updated_at`) was rewritten.
  test "a folder rename writes one folder row, not its descendants", %{user: u, vault: v} do
    tenant!(u, fn -> {:ok, _} = Rows.ensure_all(u, v.id, ["A/B/C", "A/D"]) end)

    stamps = fn ->
      %{rows: rows} =
        Repo.query!("SELECT id, updated_at FROM folders WHERE vault_id = $1", [
          Ecto.UUID.dump!(v.id)
        ])

      Map.new(rows, fn [id, at] -> {Ecto.UUID.load!(id), at} end)
    end

    [a] = tenant!(u, fn -> Rows.ids_at(u, v.id, ["A"]) end)
    before = stamps.()
    :ok = tenant!(u, fn -> Rows.rename(u, v.id, "A", "Z") end)
    changed = for {id, at} <- stamps.(), before[id] != at, do: id

    assert changed == [a]
    assert %{"Z/B/C" => _, "Z/D" => _} = Engram.FolderRows.tree(u)
  end
end
