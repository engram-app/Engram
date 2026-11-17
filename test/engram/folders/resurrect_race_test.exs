defmodule Engram.Folders.ResurrectRaceTest do
  # A resurrect read the vault's moved-folder bit with the row, before the
  # vault seq lock. When the vault's FIRST uncascaded folder move (S5)
  # committed in between, the resurrect skipped the shown-path occupancy
  # check and landed a second note at a path a moved note is shown at (a
  # user-visible duplicate). The bit is now re-read under the lock.
  #
  # async: false: the interleave seam is global app config.
  use EngramWeb.ConnCase, async: false

  alias Engram.{Crypto, Folders, Notes, ServiceConfig}

  setup :authed_api_conn

  setup %{user: user, vault: vault} do
    {:ok, user} = Crypto.ensure_user_dek(user)
    ServiceConfig.put_override(:folder_ops, true)
    on_exit(fn -> Application.delete_env(:engram, :checkpoint_interleave_hook) end)
    %{user: user, vault: vault}
  end

  defp put!(user, vault, path) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => path}, actor: "api")

    note
  end

  test "the vault's first move landing before the lock still blocks a duplicate", ctx do
    %{user: u, vault: v} = ctx
    shown = put!(u, v, "C/x.md")
    put!(u, v, "C/y.md")
    dead = put!(u, v, "T/t.md")
    :ok = Notes.delete_note(u, v, "T/t.md")

    me = self()

    Application.put_env(:engram, :checkpoint_interleave_hook, fn
      :resurrect_before_lock when self() == me ->
        unless Process.get(:moved_once) do
          Process.put(:moved_once, true)
          {:ok, _} = Folders.rename(u, v, "C", "D")
        end

      _ ->
        :ok
    end)

    # Resurrecting the tombstone at D/x.md: free when its moved bit was read,
    # shown by C/x.md's note once the move lands.
    result = Notes.genesis_crdt_note(u, v, dead.id, "D/x.md")

    assert {:error, :id_conflict, _} = result
    assert {:ok, %{id: id}} = Notes.get_note(u, v, "D/x.md")
    assert id == shown.id
  end
end
