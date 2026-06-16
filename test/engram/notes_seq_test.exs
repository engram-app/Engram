defmodule Engram.NotesSeqTest do
  use Engram.DataCase, async: true

  import Ecto.Query

  alias Engram.{Notes, Vaults}

  setup do
    user = insert_user()
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "Test"})
    %{user: user, vault: vault}
  end

  defp note_seq(user, vault, id) do
    {:ok, n} = Notes.get_note_by_id(user, vault, id)
    n.seq
  end

  # All rows in the vault (live + tombstones), read straight from the DB so
  # assertions hit persisted seq values, not in-memory structs.
  defp all_rows(user, vault) do
    {:ok, rows} =
      Engram.Repo.with_tenant(user.id, fn ->
        Engram.Repo.all(from(n in Engram.Notes.Note, where: n.vault_id == ^vault.id))
      end)

    rows
  end

  defp max_seq(user, vault) do
    all_rows(user, vault) |> Enum.map(& &1.seq) |> Enum.max()
  end

  test "upsert_note stamps a monotonic seq on insert", %{user: user, vault: vault} do
    {:ok, n1} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "A"})
    {:ok, n2} = Notes.upsert_note(user, vault, %{"path" => "b.md", "content" => "B"})
    s1 = note_seq(user, vault, n1.id)
    s2 = note_seq(user, vault, n2.id)
    assert is_integer(s1) and is_integer(s2)
    assert s2 > s1
  end

  test "upsert_note advances seq on update", %{user: user, vault: vault} do
    {:ok, n1} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "A"})
    s_insert = note_seq(user, vault, n1.id)
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "A2"})
    s_update = note_seq(user, vault, n1.id)
    assert s_update > s_insert
  end

  test "delete_note stamps a new seq on the soft-deleted row", %{user: user, vault: vault} do
    {:ok, n} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "A"})
    s_before = note_seq(user, vault, n.id)

    :ok = Notes.delete_note(user, vault, "a.md")

    {:ok, row} =
      Engram.Repo.with_tenant(user.id, fn ->
        Engram.Repo.get(Engram.Notes.Note, n.id)
      end)

    assert row.deleted_at != nil
    assert row.seq > s_before
  end

  test "rename_note stamps a new seq on the renamed row", %{user: user, vault: vault} do
    {:ok, n} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "A"})
    s_before = note_seq(user, vault, n.id)

    {:ok, _} = Notes.rename_note(user, vault, "a.md", "b.md")

    assert note_seq(user, vault, n.id) > s_before
  end

  test "rename_folder stamps one shared new seq on renamed rows + tombstones",
       %{user: user, vault: vault} do
    {:ok, n} = Notes.upsert_note(user, vault, %{"path" => "f/a.md", "content" => "A"})
    s_before = max_seq(user, vault)

    {:ok, count} = Notes.rename_folder(user, vault, "f", "g")
    assert count >= 1

    rows = all_rows(user, vault)

    # Live rows now live under the renamed folder; tombstones are soft-deleted
    # rows left at the old path. The original note id is now the live renamed row.
    live = Enum.filter(rows, &is_nil(&1.deleted_at))
    tombstones = Enum.filter(rows, &(&1.deleted_at != nil))

    renamed = Enum.find(live, &(&1.id == n.id))
    assert renamed != nil, "expected the original note row to survive as a live renamed row"
    assert renamed.seq > s_before

    assert tombstones != [], "expected at least one old-path tombstone"
    assert Enum.all?(tombstones, &(&1.seq > s_before))

    # One op = one seq: every touched row (renamed + tombstones) shares it.
    touched_seqs = Enum.map([renamed | tombstones], & &1.seq) |> Enum.uniq()
    assert length(touched_seqs) == 1
  end

  test "delete_folder stamps a new seq on the cascade-deleted rows",
       %{user: user, vault: vault} do
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "f/a.md", "content" => "A"})
    s_before = max_seq(user, vault)

    {:ok, %{deleted: deleted}} = Notes.delete_folder(user, vault, "f")
    assert deleted >= 1

    rows = all_rows(user, vault)
    cascade_deleted = Enum.filter(rows, &(&1.deleted_at != nil))

    assert cascade_deleted != [], "expected cascade-deleted rows"
    assert Enum.all?(cascade_deleted, &(&1.seq > s_before))
  end

  test "batch_upsert_notes stamps seq on inserted rows", %{user: user, vault: vault} do
    {:ok, _} =
      Notes.batch_upsert_notes(user, vault, [
        %{"path" => "x.md", "content" => "X"},
        %{"path" => "y.md", "content" => "Y"}
      ])

    rows = all_rows(user, vault)

    assert Enum.all?(rows, fn r -> is_integer(r.seq) end)
    # One op = one seq: every row inserted by a single batch shares it.
    assert length(Enum.uniq(Enum.map(rows, & &1.seq))) == 1
  end
end
