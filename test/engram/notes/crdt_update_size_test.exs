defmodule Engram.Notes.CrdtUpdateSizeTest do
  # The CRDT update log's write stream was unmeasured: only the survivors'
  # sizes could be read off the table. Every append now reports its update's
  # size, and an update over 64 KB (a whole body inserted through a room:
  # genesis fallback, reseed) asks for a checkpoint now, so the big row folds
  # into the snapshot in seconds instead of waiting out the settle delay.
  use Engram.DataCase, async: true

  alias Engram.Notes
  alias Engram.Notes.{CrdtBridge, CrdtPersistence}

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "T", Ecto.UUID.generate())

    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "p.md", "content" => "x"}, actor: "api")

    st = %{user_id: user.id, vault_id: vault.id, note_id: note.id}
    # Stands in for the room's checkpoint timer.
    Process.put(:crdt_timer_pid, self())
    on_exit(fn -> Process.delete(:crdt_timer_pid) end)
    %{st: st}
  end

  defp append(st, text) do
    {:ok, %{state: upd}} = CrdtBridge.merge_plaintext(nil, text)
    _ = CrdtPersistence.update_v1(st, upd, st.note_id, CrdtBridge.new_doc())
    upd
  end

  test "each append reports its update's size", %{st: st} do
    ref = make_ref()
    me = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:engram, :crdt, :update_appended],
      fn _, m, meta, _ -> send(me, {:appended, m, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

    upd = append(st, "small")
    size = byte_size(upd)
    assert_receive {:appended, %{bytes: ^size}, meta}
    assert meta == %{}
  end

  test "a small update leaves the checkpoint to its timer", %{st: st} do
    append(st, "small")
    refute_receive :tick, 50
  end

  test "an update over 64 KB asks for a checkpoint now", %{st: st} do
    # Random text: zstd cannot shrink it, and the update carries it whole.
    big = :crypto.strong_rand_bytes(60_000) |> Base.encode64()
    assert byte_size(append(st, big)) > 65_536
    assert_receive :tick
  end
end
