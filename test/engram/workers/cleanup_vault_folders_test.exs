defmodule Engram.Workers.CleanupVaultFoldersTest do
  # A vault purge removes its folder rows too, after the notes and attachments
  # that point at them: batches of one row each, so the notes go in separate
  # transactions while the folders they reference are still there.
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Engram.Crypto
  alias Engram.Folders.{Folder, Rows}
  alias Engram.Repo
  alias Engram.Workers.CleanupVault

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    Application.put_env(:engram, :cleanup_vault_batch_size, 1)

    on_exit(fn ->
      Application.delete_env(:engram, :qdrant_url)
      Application.delete_env(:engram, :cleanup_vault_batch_size)
    end)

    Bypass.stub(bypass, "POST", "/collections/engram_notes/points/delete", fn conn ->
      Plug.Conn.send_resp(conn, 200, ~s({"result": {"status": "acknowledged"}}))
    end)

    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)

    vault =
      insert(:vault,
        user: user,
        deleted_at: DateTime.add(DateTime.utc_now(), -31, :day) |> DateTime.truncate(:second)
      )

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        {:ok, _} = Rows.ensure(user, vault.id, "A/B/C")
        {:ok, _} = Rows.ensure(user, vault.id, "A/D")
      end)

    for n <- 1..3 do
      Engram.Fixtures.insert_note!(user, vault, %{
        path: "A/B/C/#{n}.md",
        content: "x",
        folder: "A/B/C"
      })
    end

    %{user: user, vault: vault}
  end

  test "hard delete leaves no folder rows and no notes", %{user: user, vault: vault} do
    assert {:ok, 4} =
             Repo.with_tenant(user.id, fn ->
               Repo.aggregate(from(f in Folder, where: f.vault_id == ^vault.id), :count)
             end)

    assert :ok = CleanupVault.perform_cleanup(vault.id, user.id)

    {:ok, folders} =
      Repo.with_tenant(user.id, fn ->
        Repo.aggregate(from(f in Folder, where: f.user_id == ^user.id), :count)
      end)

    assert folders == 0
  end
end
