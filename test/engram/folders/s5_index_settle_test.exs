defmodule Engram.Folders.S5IndexSettleTest do
  # The settle after an S5 (uncascaded) rename's transaction must leave the
  # index room at the SHOWN path: settle reads rows through
  # `get_note_meta_by_ids/3`, which derives it (`Location.put_paths/3`).
  # Reading the stored path instead would undo every S5 move.
  use Engram.DataCase, async: false

  alias Engram.{Crypto, Folders, Notes, Repo, ServiceConfig, Vaults}
  alias Engram.Folders.WriteStop
  alias Engram.Notes.{CrdtIndexDoc, CrdtIndexRegistry, Identity}
  alias Yex.Sync.SharedDoc

  setup do
    prev = Application.get_env(:engram, :storage)
    Application.put_env(:engram, :storage, Engram.MockStorage)
    on_exit(fn -> Application.put_env(:engram, :storage, prev) end)
    Mox.stub(Engram.MockStorage, :put, fn _key, _bin, _opts -> :ok end)
    Mox.stub(Engram.MockStorage, :delete, fn _key -> :ok end)

    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "S5Settle", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  defp note(ctx, path) do
    {:ok, note} =
      Notes.upsert_note(ctx.user, ctx.vault, %{"path" => path, "content" => "x"}, actor: "api")

    :ok = Identity.claim(ctx.user, ctx.vault.id, [{path, note.id}])
    note
  end

  defp live_path(room, note_id) do
    me = self()

    :ok =
      SharedDoc.update_doc(room, fn doc ->
        map = doc |> Yex.Doc.get_map(CrdtIndexDoc.map_name()) |> Yex.Map.to_map()
        send(me, {:live_map, map})
      end)

    assert_receive {:live_map, map}, 2_000
    Enum.find_value(map, fn {path, v} -> if v["note_id"] == note_id, do: path end)
  end

  defp uncascaded_count(ctx) do
    Repo.with_tenant!(ctx.user.id, fn ->
      Repo.aggregate(
        from(f in Engram.Folders.Folder,
          where: f.vault_id == ^ctx.vault.id and not f.notes_cascaded
        ),
        :count
      )
    end)
  end

  test "write stop ON: settle leaves the index at the shown (new) path", ctx do
    ServiceConfig.put_override(:folder_ops, true)
    assert WriteStop.on?()
    {:ok, room} = CrdtIndexRegistry.ensure_observed(ctx.user.id, ctx.vault.id)
    n = note(ctx, "Docs/sub/n.md")
    m = note(ctx, "Docs/m.md")

    assert {:ok, _} = Folders.rename(ctx.user, ctx.vault, "Docs", "Archive")
    # Proves S5 ran (one folder row, notes not cascaded).
    assert uncascaded_count(ctx) == 1

    assert live_path(room, n.id) == "Archive/sub/n.md"
    assert live_path(room, m.id) == "Archive/m.md"
    assert {:ok, %{path: "Archive/sub/n.md"}} = Notes.get_note_by_id(ctx.user, ctx.vault, n.id)

    # A second S5 rename on top of the first (chain of moves).
    assert {:ok, _} = Folders.rename(ctx.user, ctx.vault, "Archive", "Old/Archive")
    assert live_path(room, n.id) == "Old/Archive/sub/n.md"

    assert {:ok, %{path: "Old/Archive/sub/n.md"}} =
             Notes.get_note_by_id(ctx.user, ctx.vault, n.id)
  end

  test "write stop OFF (release A): cascade, index at the new path", ctx do
    ServiceConfig.put_override(:folder_ops, true)
    ServiceConfig.put_override(:folder_write_stop, false)
    refute WriteStop.on?()
    {:ok, room} = CrdtIndexRegistry.ensure_observed(ctx.user.id, ctx.vault.id)
    n = note(ctx, "Docs/sub/n.md")

    assert {:ok, _} = Folders.rename(ctx.user, ctx.vault, "Docs", "Archive")
    assert uncascaded_count(ctx) == 0
    assert live_path(room, n.id) == "Archive/sub/n.md"
  end
end
