defmodule EngramWeb.CrdtCreateNameConflictTest do
  # A crdt_create at a path whose folder row and name another live note holds
  # (`notes_name_live`, a stale name key) replies exactly as a path index
  # refusal does (`create_failed`, which the web app name-bumps on), never a
  # crashed channel or a re-mint.
  use EngramWeb.ChannelCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.{Crypto, Notes, Repo, Vaults}

  setup do
    EngramWeb.RateLimiter.reset_buckets!()
    on_exit(fn -> EngramWeb.RateLimiter.reset_buckets!() end)

    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    {:ok, vault, _} = Vaults.register_vault(user, "NameConflict", Ecto.UUID.generate())

    {:ok, holder} =
      Notes.upsert_note(user, vault, %{"path" => "F/a.md", "content" => "a"}, actor: "api")

    Engram.Fixtures.stale_name_holder!(user, vault, holder, "F/x.md")
    %{user: user, vault: vault}
  end

  test "crdt_create replies create_failed, as for a path index refusal", %{
    user: user,
    vault: vault
  } do
    {:ok, _, socket} =
      subscribe_and_join(
        user_socket(user),
        EngramWeb.CrdtChannel,
        "crdt:#{user.id}:#{vault.id}",
        %{"crdt_proto" => 2}
      )

    Sandbox.allow(Repo, self(), socket.channel_pid)

    ref = push(socket, "crdt_create", %{"doc_id" => Ecto.UUID.generate(), "path" => "F/x.md"})
    # Every changeset refusal of a create (a path index's included) replies
    # `create_failed`; the name refusal is that changeset
    # (name_live_conflict_test.exs compares it to a path index's).
    assert_reply ref, :error, %{reason: "create_failed"}
  end
end
