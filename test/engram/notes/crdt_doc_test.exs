defmodule Engram.Notes.CrdtDocTest do
  use Engram.DataCase, async: false

  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Notes.{CrdtBridge, CrdtRegistry, Note}

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "CrdtDocTest"})
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "p.md", "content" => "before"})
    %{user: user, vault: vault, note: note}
  end

  test "supervisor shutdown runs terminate → unbind → edits materialize", ctx do
    %{user: user, vault: vault, note: note} = ctx

    # Override the checkpoint timer to huge settle/ceiling/eager values so it
    # cannot fire during the synchronous update_doc → terminate_child window.
    # Large integers (not :infinity) because the timer's min/2 arithmetic would
    # misbehave on atoms. Must be set BEFORE the room starts so the timer's
    # init/1 picks up the overridden config.
    prev = Application.get_env(:engram, Engram.Notes.CrdtCheckpointTimer, [])

    Application.put_env(:engram, Engram.Notes.CrdtCheckpointTimer,
      settle_ms: 600_000,
      ceiling_ms: 600_000,
      eager_ms: 600_000
    )

    on_exit(fn -> Application.put_env(:engram, Engram.Notes.CrdtCheckpointTimer, prev) end)

    {:ok, room} = CrdtRegistry.ensure_started(user.id, vault.id, note.id)

    :ok =
      Yex.Sync.SharedDoc.update_doc(room, fn doc ->
        doc
        |> Yex.Doc.get_text(CrdtBridge.text_name())
        |> CrdtBridge.diff_into_text("before AND SHUTDOWN EDIT")
      end)

    # Simulate the deploy path: supervisor-initiated graceful shutdown.
    :ok = DynamicSupervisor.terminate_child(Engram.Notes.CrdtDocSupervisor, room)

    {:ok, {:ok, updated}} =
      Repo.with_tenant(user.id, fn ->
        Crypto.maybe_decrypt_note_fields(Repo.get!(Note, note.id), user)
      end)

    assert updated.content =~ "SHUTDOWN EDIT"
  end
end
