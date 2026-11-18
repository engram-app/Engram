defmodule Engram.Migrations.DropFoldersFullPathHmacTest do
  # S6 step 3 phase 3 (20261118120000): `folders.full_path_hmac` and its
  # index `folders_full_path` are gone; nothing reads or writes them since
  # the write stop. Red before the drop migration: both still exist.
  use Engram.DataCase, async: false

  alias Engram.Repo

  test "the column and its index are dropped" do
    %{rows: [[columns]]} =
      Repo.query!("""
      SELECT count(*)::int FROM pg_attribute
      WHERE attrelid = 'folders'::regclass AND attname = 'full_path_hmac' AND NOT attisdropped
      """)

    assert columns == 0
    assert %{rows: [[nil]]} = Repo.query!("SELECT to_regclass('folders_full_path')")
  end

  test "folder writes and reads work without it" do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)

    {:ok, %{"A/B" => b}} =
      Repo.with_tenant!(user.id, fn -> Engram.Folders.Rows.ensure_all(user, vault.id, ["A/B"]) end)

    assert %{"A/B" => %{id: ^b}} = Engram.FolderRows.tree(user)
  end
end
