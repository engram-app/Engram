defmodule Engram.FoldersTest do
  use Engram.DataCase, async: false

  alias Engram.{Attachments, Folders, Notes}

  setup do
    prev = Application.get_env(:engram, :storage)
    Application.put_env(:engram, :storage, Engram.MockStorage)
    on_exit(fn -> Application.put_env(:engram, :storage, prev) end)
    Mox.stub(Engram.MockStorage, :put, fn _key, _bin, _opts -> :ok end)
    Mox.stub(Engram.MockStorage, :delete, fn _key -> :ok end)

    user = insert(:user)
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp att_paths(user, vault) do
    {:ok, metas} = Attachments.list_attachments(user, vault)
    metas |> Enum.map(& &1.path) |> Enum.sort()
  end

  defp put_att(user, vault, path) do
    {:ok, _} =
      Attachments.upsert_attachment(user, vault, %{
        "path" => path,
        "content_base64" => Base.encode64("x")
      })
  end

  test "rename/4 moves both a note and an attachment under the folder", %{
    user: user,
    vault: vault
  } do
    {:ok, _note} = Notes.upsert_note(user, vault, %{"path" => "Docs/n.md", "content" => "hi"})
    put_att(user, vault, "Docs/a.png")

    assert {:ok, %{notes: 1, attachments: 1}} = Folders.rename(user, vault, "Docs", "Archive")
    assert att_paths(user, vault) == ["Archive/a.png"]
  end

  test "batch_delete/3 soft-deletes the folder's attachments", %{user: user, vault: vault} do
    {:ok, marker} = Notes.create_folder_marker(user, vault, "Docs")
    put_att(user, vault, "Docs/a.png")

    assert {:ok, %{notes: _, attachments: 1}} = Folders.batch_delete(user, vault, [marker.id])
    assert att_paths(user, vault) == []
  end

  test "batch_move/4 moves the folder's attachments under the target", %{user: user, vault: vault} do
    {:ok, src} = Notes.create_folder_marker(user, vault, "Docs")
    {:ok, _dst} = Notes.create_folder_marker(user, vault, "Archive")
    put_att(user, vault, "Docs/a.png")

    assert {:ok, %{notes: _, attachments: 1}} =
             Folders.batch_move(user, vault, [src.id], {:path, "Archive"})

    assert att_paths(user, vault) == ["Archive/Docs/a.png"]
  end

  describe "single-scan partition across multiple folders (#9)" do
    test "batch_delete/3 soft-deletes attachments under 2+ folders in one scan", %{
      user: user,
      vault: vault
    } do
      {:ok, m1} = Notes.create_folder_marker(user, vault, "Docs")
      {:ok, m2} = Notes.create_folder_marker(user, vault, "Notes")
      put_att(user, vault, "Docs/a.png")
      put_att(user, vault, "Docs/sub/b.png")
      put_att(user, vault, "Notes/c.png")
      put_att(user, vault, "Keep/d.png")

      assert {:ok, %{attachments: 3}} = Folders.batch_delete(user, vault, [m1.id, m2.id])

      # Only the attachment outside both deleted folders survives.
      assert att_paths(user, vault) == ["Keep/d.png"]
    end

    test "batch_move/4 relocates attachments under 2+ folders in one scan", %{
      user: user,
      vault: vault
    } do
      {:ok, s1} = Notes.create_folder_marker(user, vault, "Docs")
      {:ok, s2} = Notes.create_folder_marker(user, vault, "Notes")
      {:ok, _dst} = Notes.create_folder_marker(user, vault, "Archive")
      put_att(user, vault, "Docs/a.png")
      put_att(user, vault, "Notes/sub/b.png")
      put_att(user, vault, "Keep/c.png")

      assert {:ok, %{attachments: 2}} =
               Folders.batch_move(user, vault, [s1.id, s2.id], {:path, "Archive"})

      assert att_paths(user, vault) == [
               "Archive/Docs/a.png",
               "Archive/Notes/sub/b.png",
               "Keep/c.png"
             ]
    end
  end

  defp note_path(user, vault, id) do
    {:ok, note} = Notes.get_note_by_id(user, vault, id)
    note.path
  end

  describe "atomicity across the notes + attachments legs" do
    test "rename/4 rolls BOTH legs back when the attachment leg conflicts", %{
      user: user,
      vault: vault
    } do
      # Notes leg moves cleanly (Docs/n.md -> Archive/n.md), but the attachment
      # leg conflicts: Archive/a.png is already occupied. Pre-Bug-3 the notes
      # commit stuck while attachments didn't → permanent split state. The fix
      # makes the coordinator atomic: a conflict rolls the note move back too.
      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "Docs/n.md", "content" => "hi"})
      put_att(user, vault, "Docs/a.png")
      put_att(user, vault, "Archive/a.png")

      assert {:error, :conflict} = Folders.rename(user, vault, "Docs", "Archive")

      # The note must NOT have moved — both tables roll back together.
      assert note_path(user, vault, note.id) == "Docs/n.md"
      # Source attachment untouched too.
      assert "Docs/a.png" in att_paths(user, vault)
    end

    test "batch_move/4 rolls BOTH legs back when the attachment leg conflicts", %{
      user: user,
      vault: vault
    } do
      # Notes leg moves the marker cleanly, attachment leg conflicts on a
      # pre-occupied destination. Atomic coordinator must roll the note move back.
      {:ok, src} = Notes.create_folder_marker(user, vault, "Docs")
      {:ok, _dst} = Notes.create_folder_marker(user, vault, "Archive")
      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "Docs/n.md", "content" => "hi"})
      put_att(user, vault, "Docs/a.png")
      # Pre-occupy the attachment move destination (Archive/Docs/a.png).
      put_att(user, vault, "Archive/Docs/a.png")

      assert {:error, :conflict} =
               Folders.batch_move(user, vault, [src.id], {:path, "Archive"})

      # Note move rolled back.
      assert note_path(user, vault, note.id) == "Docs/n.md"
    end

    test "batch_delete/3 wraps both legs in one transaction (atomic across tables)" do
      # Bug 6: batch_delete deleted notes (committed) then attachments; an
      # attachment-leg failure left notes gone, skipped idempotency+broadcast, and
      # a retry 404'd (masked data loss). Runtime injection isn't feasible (the
      # attachment soft-delete leg doesn't error on the happy path), so assert the
      # structural guarantee: the coordinator function body runs inside a single
      # Repo.transaction wrapping BOTH legs with a Repo.rollback on any error.
      src = File.read!("lib/engram/folders.ex")

      [_, body | _] = String.split(src, "def batch_delete(user, vault, marker_ids) do")
      body = body |> String.split(~r/\n  (def|defp) /) |> hd()

      assert body =~ "atomic(",
             "batch_delete must run both legs through the atomic/1 wrapper (Bug 6)"

      [_, atomic_body | _] = String.split(src, "defp atomic(fun) do")
      atomic_body = atomic_body |> String.split(~r/\n  (def|defp) /) |> hd()

      assert atomic_body =~ "Repo.transaction",
             "atomic/1 must wrap both legs in one Repo.transaction"

      assert atomic_body =~ "Repo.rollback",
             "atomic/1 must Repo.rollback on a leg error so notes don't half-delete"
    end
  end

  test "batch_delete/3 with empty ids returns zero counts", %{user: user, vault: vault} do
    assert {:ok, %{notes: 0, attachments: 0}} = Folders.batch_delete(user, vault, [])
  end

  test "batch_move/4 with empty ids returns zero counts", %{user: user, vault: vault} do
    assert {:ok, %{notes: 0, attachments: 0}} =
             Folders.batch_move(user, vault, [], {:path, "Archive"})
  end
end
