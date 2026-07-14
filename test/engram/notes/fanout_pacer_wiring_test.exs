defmodule Engram.Notes.FanoutPacerWiringTest do
  use Engram.DataCase, async: true

  alias Engram.Notes

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Test"})
    %{user: user, vault: vault}
  end

  test "a non-CRDT-origin write still fans out note_yjs_update via the pacer", %{
    user: user,
    vault: vault
  } do
    # Pacing is OFF in test env (config/test.exs) → pacer emits inline, so the
    # fan-out is observable synchronously exactly as before the swap.
    EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "w.md", "content" => "# W", "mtime" => 1.0})

    assert_receive(
      %Phoenix.Socket.Broadcast{
        event: "note_yjs_update",
        payload: %{"note_id" => note_id}
      },
      500
    )

    assert note_id == note.id
  end
end
