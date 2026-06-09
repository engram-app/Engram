defmodule Engram.Notes.MaterializationTest do
  use Engram.DataCase, async: true

  alias Engram.Notes
  alias Engram.Notes.Materialization

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Test"})

    %{user: user, vault: vault}
  end

  test "empty vault: no inserts, returns count 0", %{user: user, vault: vault} do
    assert {:ok, %{inserted: 0, existing: 0}} = Materialization.run(user, vault)
  end

  test "inserts missing folder markers for every distinct folder path", %{
    user: user,
    vault: vault
  } do
    {:ok, _} =
      Notes.upsert_note(user, vault, %{
        "path" => "a/b/c.md",
        "content" => "c",
        "mtime" => 1.0
      })

    {:ok, _} =
      Notes.upsert_note(user, vault, %{
        "path" => "x/y.md",
        "content" => "y",
        "mtime" => 2.0
      })

    # "a/b/c.md" implies folders "a" and "a/b". "x/y.md" implies "x". = 3 inserts.
    assert {:ok, %{inserted: 3, existing: 0}} = Materialization.run(user, vault)

    markers = Notes.list_folder_markers(user, vault)
    paths = markers |> Enum.map(& &1.folder) |> Enum.sort()
    assert paths == ["a", "a/b", "x"]
  end

  test "idempotent re-run reports existing, inserts nothing", %{user: user, vault: vault} do
    {:ok, _} =
      Notes.upsert_note(user, vault, %{
        "path" => "a/b/c.md",
        "content" => "c",
        "mtime" => 1.0
      })

    {:ok, %{inserted: 2, existing: 0}} = Materialization.run(user, vault)
    assert {:ok, %{inserted: 0, existing: 2}} = Materialization.run(user, vault)
  end

  test "preserves HMAC binding on inserted markers", %{user: user, vault: vault} do
    {:ok, _} =
      Notes.upsert_note(user, vault, %{
        "path" => "Projects/notes.md",
        "content" => "x",
        "mtime" => 1.0
      })

    {:ok, _} = Materialization.run(user, vault)
    [marker] = Notes.list_folder_markers(user, vault)
    assert marker.folder_hmac != nil
    assert byte_size(marker.folder_hmac) == 32
  end
end
