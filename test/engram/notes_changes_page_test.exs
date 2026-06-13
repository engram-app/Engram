defmodule Engram.NotesChangesPageTest do
  use Engram.DataCase, async: true

  alias Engram.Notes
  alias Engram.Notes.Note
  alias Engram.Repo

  @epoch ~U[2020-01-01 00:00:00.000000Z]

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Test"})
    %{user: user, vault: vault}
  end

  defp seed_notes(user, vault, n) do
    for i <- 1..n do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "n#{String.pad_leading(to_string(i), 3, "0")}.md",
          "content" => "note #{i}",
          "mtime" => i * 1.0
        })

      note
    end
  end

  describe "list_changes_page/4" do
    test "pages through all changes without overlap or loss", %{user: user, vault: vault} do
      seed_notes(user, vault, 5)

      assert {:ok, %{changes: page1, has_more: true, next_cursor: cursor1}} =
               Notes.list_changes_page(user, vault, @epoch, limit: 2)

      assert length(page1) == 2
      assert is_binary(cursor1)

      assert {:ok, %{changes: page2, has_more: true, next_cursor: cursor2}} =
               Notes.list_changes_page(user, vault, @epoch, limit: 2, cursor: cursor1)

      assert {:ok, %{changes: page3, has_more: false, next_cursor: nil}} =
               Notes.list_changes_page(user, vault, @epoch, limit: 2, cursor: cursor2)

      all_ids = Enum.map(page1 ++ page2 ++ page3, & &1.id)
      assert length(all_ids) == 5
      assert length(Enum.uniq(all_ids)) == 5
    end

    test "a full final page reports has_more false on the follow-up call", %{
      user: user,
      vault: vault
    } do
      seed_notes(user, vault, 2)

      assert {:ok, %{changes: changes, has_more: false, next_cursor: nil}} =
               Notes.list_changes_page(user, vault, @epoch, limit: 2)

      assert length(changes) == 2
    end

    test "identical updated_at timestamps don't lose or duplicate rows across pages", %{
      user: user,
      vault: vault
    } do
      notes = seed_notes(user, vault, 3)
      shared_ts = DateTime.utc_now()
      ids = Enum.map(notes, & &1.id)

      {:ok, _} =
        Repo.with_tenant(user.id, fn ->
          Repo.update_all(from(n in Note, where: n.id in ^ids),
            set: [updated_at: shared_ts]
          )
        end)

      assert {:ok, %{changes: page1, has_more: true, next_cursor: cursor}} =
               Notes.list_changes_page(user, vault, @epoch, limit: 2)

      assert {:ok, %{changes: page2, has_more: false}} =
               Notes.list_changes_page(user, vault, @epoch, limit: 2, cursor: cursor)

      collected = Enum.map(page1 ++ page2, & &1.id)
      assert Enum.sort(collected) == Enum.sort(ids)
    end

    test "every change carries content_hash", %{user: user, vault: vault} do
      seed_notes(user, vault, 1)

      assert {:ok, %{changes: [change]}} =
               Notes.list_changes_page(user, vault, @epoch, limit: 10)

      assert is_binary(change.content_hash)
      assert change.content == "note 1"
    end

    test "fields: :meta returns content_hash but no content", %{user: user, vault: vault} do
      seed_notes(user, vault, 1)

      assert {:ok, %{changes: [change]}} =
               Notes.list_changes_page(user, vault, @epoch, limit: 10, fields: :meta)

      assert is_binary(change.content_hash)
      assert change.content == nil
      assert change.path == "n001.md"
    end

    test "includes deleted notes", %{user: user, vault: vault} do
      seed_notes(user, vault, 2)
      :ok = Notes.delete_note(user, vault, "n001.md")

      assert {:ok, %{changes: changes}} =
               Notes.list_changes_page(user, vault, @epoch, limit: 10)

      deleted = Enum.find(changes, & &1.deleted)
      assert deleted.path == "n001.md"
    end

    test "invalid cursor returns an error", %{user: user, vault: vault} do
      assert {:error, :invalid_cursor} =
               Notes.list_changes_page(user, vault, @epoch, limit: 10, cursor: "garbage!!")
    end
  end
end
