defmodule Engram.Folders.ChainNotHashTest do
  @moduledoc """
  S6 step 3, read switch (Engram#2523): the folder writers (`Rows.ensure/4`
  and its batch), the move cycle check and the folder delete fence find a
  folder by its parent chain, never by `folders.full_path_hmac`. From the
  next release a folder rename rewrites only the renamed row, so a
  descendant keeps the hash of its OLD path. Each test leaves exactly that
  stale hash and asserts the chain answer. Red before: each read the hash.
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
    {:ok, fk} = Crypto.dek_filter_key(user)
    %{user: user, vault: vault, fk: fk}
  end

  defp tenant!(user, fun) do
    {:ok, result} = Repo.with_tenant(user.id, fun)
    result
  end

  # The hash a one-row rename leaves on a descendant (raw SQL: the column is
  # out of the schema since S6 step 3's write stop).
  defp stale!(fk, ids) do
    Repo.query!("UPDATE folders SET full_path_hmac = $1 WHERE id = ANY($2)", [
      Rows.path_hmac(fk, "A/B"),
      Enum.map(ids, &Ecto.UUID.dump!/1)
    ])
  end

  # "A/B" then A renamed to C, with B left holding the hash of "A/B": the
  # state a one-row rename leaves. Returns B's id.
  defp stale_descendant(%{user: u, vault: v, fk: fk}) do
    tenant!(u, fn ->
      {:ok, b} = Rows.ensure(u, v.id, "A/B")
      :ok = Rows.rename(u, v.id, "A", "C")

      stale!(fk, [b])
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
    %{user: u, vault: v, fk: fk} = ctx

    {:ok, note} =
      Notes.upsert_note(u, v, %{"path" => "A/B/x.md", "content" => "x", "mtime" => 1.0},
        actor: "api"
      )

    {:ok, matches} = Notes.scan_folders(u, v, ["A/B"])
    assert note.id in Enum.map(matches, & &1.id)

    # After the scan: A renamed to C in one row, B keeps the old hash.
    tenant!(u, fn ->
      b = Rows.ids_at(u, v.id, ["A/B"])
      :ok = Rows.rename(u, v.id, "A", "C")

      stale!(fk, b)
    end)

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

  # Red/green audit gaps (S6 step 3 read switch): each leaves a stale hash on
  # a live row and asserts the chain answer.
  defp put_note!(u, v, path) do
    {:ok, n} = Notes.upsert_note(u, v, %{"path" => path, "content" => "x"}, actor: "api")
    n
  end

  defp row_id(u, v, path), do: tenant!(u, fn -> Rows.ids_by_path(u, v.id, [path]) end)[path]

  defp stale_at!(fk, id, path) do
    Repo.query!("UPDATE folders SET full_path_hmac = $1 WHERE id = $2", [
      Rows.path_hmac(fk, path),
      Ecto.UUID.dump!(id)
    ])
  end

  test "unmark_explicit finds the row by chain, not by a stale hash", ctx do
    %{user: u, vault: v, fk: fk} = ctx
    {:ok, _} = Notes.create_folder_marker(u, v, "C/M")
    m = row_id(u, v, "C/M")
    stale_at!(fk, m, "A/M")

    :ok = tenant!(u, fn -> Rows.unmark_explicit(u, v.id, "C/M") end)
    assert %{explicit: false} = Engram.FolderRows.row(m)
  end

  test "a folder delete keeps a row a live marker names by its chain path", ctx do
    %{user: u, vault: v, fk: fk} = ctx
    {:ok, _} = Notes.create_folder_marker(u, v, "C/B")
    b = row_id(u, v, "C/B")
    stale_at!(fk, b, "A/B")

    _ = tenant!(u, fn -> Rows.soft_delete(u, v.id, ["C"], Ecto.UUID.generate()) end)
    assert %{deleted_at: nil} = Engram.FolderRows.row(b)
  end

  test "a folder name that will not decrypt: its notes are still scanned, with no row path",
       ctx do
    %{user: u, vault: v} = ctx
    note = put_note!(u, v, "A/B/n.md")
    b = row_id(u, v, "A/B")

    Repo.query!("UPDATE folders SET name_ciphertext = '\\x00' WHERE id = $1", [Ecto.UUID.dump!(b)])

    {:ok, rows} = Notes.scan_folders(u, v, ["A"])
    assert [%{folder_row_path: nil, folder: "A/B"}] = Enum.filter(rows, &(&1.id == note.id))
  end
end
