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
  alias Engram.Folders.{Folder, Rows}
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

  # "A/B" then A renamed to C, with B left holding the hash of "A/B": the
  # state a one-row rename leaves. Returns B's id.
  defp stale_descendant(%{user: u, vault: v, fk: fk}) do
    tenant!(u, fn ->
      {:ok, b} = Rows.ensure(u, v.id, "A/B")
      :ok = Rows.rename(u, v.id, "A", "C")

      from(f in Folder, where: f.id == ^b)
      |> Repo.update_all(set: [full_path_hmac: Rows.path_hmac(fk, "A/B")])

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

      from(f in Folder, where: f.id in ^b)
      |> Repo.update_all(set: [full_path_hmac: Rows.path_hmac(fk, "A/B")])
    end)

    assert {:ok, %{notes: 0}} = Notes.delete_scanned(u, v, matches)
    assert %{deleted_at: nil} = Repo.with_tenant!(u.id, fn -> Repo.get!(Notes.Note, note.id) end)
  end
end
