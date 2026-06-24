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

    assert {:ok, %{attachments: 1}} = Folders.batch_delete(user, vault, [marker.id])
    assert att_paths(user, vault) == []
  end

  test "batch_move/4 moves the folder's attachments under the target", %{user: user, vault: vault} do
    {:ok, src} = Notes.create_folder_marker(user, vault, "Docs")
    {:ok, _dst} = Notes.create_folder_marker(user, vault, "Archive")
    put_att(user, vault, "Docs/a.png")

    assert {:ok, %{attachments: 1}} =
             Folders.batch_move(user, vault, [src.id], {:path, "Archive"})

    assert att_paths(user, vault) == ["Archive/Docs/a.png"]
  end
end
