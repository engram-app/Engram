defmodule Engram.Folders.DeltaFixesTest do
  # Fixes from the delta review: every reader of `folder_ref_id` treats a ref to
  # a deleted folder row as unresolved, the move guard also checks rows, and a
  # bad folder is reported once per listing.
  use Engram.DataCase, async: false

  alias Engram.{Attachments, DataMigrations, Folders, Notes, Repo}
  alias Engram.DataMigrations.FolderTable
  alias Engram.FolderRows
  alias Engram.Folders.Rows

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    Application.put_env(:engram, :folder_ref_verify_margin_s, 0)
    on_exit(fn -> Application.delete_env(:engram, :folder_ref_verify_margin_s) end)
    %{user: user, vault: vault}
  end

  defp put_note(user, vault, path) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => "# T\n\nbody"}, actor: "api")

    note
  end

  defp put_att(user, vault, path) do
    {:ok, att} =
      Attachments.upsert_attachment(user, vault, %{
        "path" => path,
        "content_base64" => Base.encode64("bytes of " <> path)
      })

    att
  end

  defp dump(id), do: Ecto.UUID.dump!(id)

  defp kill_row!(id),
    do: Repo.query!("UPDATE folders SET deleted_at = now() WHERE id = $1", [dump(id)])

  describe "Med 1: no reader trusts a ref to a deleted folder row" do
    test "the folder counts do not list a phantom folder", %{user: u, vault: v} do
      note = put_note(u, v, "Y/n.md")
      put_note(u, v, "Other/o.md")
      other = FolderRows.tree(u)["Other"].id
      # Y's note now names the Other row, which is then deleted.
      Repo.query!("UPDATE notes SET folder_ref_id = $1 WHERE id = $2", [
        dump(other),
        dump(note.id)
      ])

      kill_row!(other)

      {:ok, counts} = Notes.list_folders_with_counts(u, v)
      assert Map.new(counts, &{&1.folder, &1.count}) == %{"Y" => 1, "Other" => 1}
      assert Enum.count(counts, &(&1.folder == "Other")) == 1
      {:ok, folders} = Notes.list_folders(u, v)
      assert folders == ["Other", "Y"]
    end

    test "an old attachment with a dead ref is still found by its folder", %{user: u, vault: v} do
      att = put_att(u, v, "Y/a.png")
      put_att(u, v, "Other/o.png")
      other = FolderRows.tree(u)["Other"].id

      Repo.query!("UPDATE attachments SET folder_ref_id = $1 WHERE id = $2", [
        dump(other),
        dump(att.id)
      ])

      kill_row!(other)
      # Verified after every write: the reference is "trusted" by age.
      DataMigrations.mark_done(FolderTable.name(), FolderTable.version())

      assert {:ok, %{attachments: 1}} = Folders.rename(u, v, "Y", "Z")
      {:ok, metas} = Attachments.list_attachments(u, v)
      assert "Z/a.png" in Enum.map(metas, & &1.path)
    end
  end

  describe "move guard" do
    test "also refuses by row, where a stale path hash would let it through", %{user: u, vault: v} do
      put_note(u, v, "A/B/x.md")
      t = FolderRows.tree(u)
      {:ok, fk} = Engram.Crypto.dek_filter_key(u)
      # A/B carries a stale hash equal to the path "X/Y".
      Repo.query!("UPDATE folders SET full_path_hmac = $1 WHERE id = $2", [
        Rows.path_hmac(fk, "X/Y"),
        dump(t["A/B"].id)
      ])

      assert {:error, :invalid_path} = Notes.rename_folder(u, v, "A", "X/Y/Z")
      assert FolderRows.tree(u)["A"].id == t["A"].id
    end

    test "an empty path is a clean error, not a crash after the claim", %{user: u, vault: v} do
      put_note(u, v, "A/x.md")
      assert {:error, :invalid_path} = Notes.rename_folder(u, v, "A", "")
      assert {:error, :invalid_path} = Notes.rename_folder(u, v, "", "B")
    end
  end

  describe "an unreadable folder is reported once per listing" do
    test "a bad parent with three children is one event", %{user: u, vault: v} do
      for c <- ~w(c1 c2 c3), do: put_note(u, v, "Bad/#{c}/n.md")
      bad = FolderRows.tree(u)["Bad"].id
      Repo.query!("UPDATE folders SET name_ciphertext = '\\x00' WHERE id = $1", [dump(bad)])

      handler = "once-#{System.unique_integer([:positive])}"
      test = self()

      :telemetry.attach(
        handler,
        [:engram, :folders, :row_undecryptable],
        fn _, m, _, _ -> send(test, {:event, m.count}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, []} = Notes.list_folders_with_counts(u, v)
      assert_received {:event, 1}
      refute_received {:event, _}
    end
  end
end
