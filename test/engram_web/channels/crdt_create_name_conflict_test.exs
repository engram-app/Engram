defmodule EngramWeb.CrdtCreateNameConflictTest do
  # A crdt_create at a path whose folder row and name another live note holds
  # (`notes_name_live`, a stale name key) is a taken name, answered as the
  # wire answers every taken name (`id_conflict`, final for every client; the
  # web app name-bumps on it), never `create_failed` (retried forever by the
  # plugin, under its vault-wide create pause), a crashed channel or a re-mint.
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

  test "crdt_create replies id_conflict, as for any taken name", %{user: user, vault: vault} do
    {:ok, _, socket} =
      subscribe_and_join(
        user_socket(user),
        EngramWeb.CrdtChannel,
        "crdt:#{user.id}:#{vault.id}",
        %{"crdt_proto" => 2}
      )

    Sandbox.allow(Repo, self(), socket.channel_pid)

    id = Ecto.UUID.generate()
    ref = push(socket, "crdt_create", %{"doc_id" => id, "path" => "F/x.md"})
    assert_reply ref, :error, %{reason: "id_conflict", doc_id: ^id}
  end

  # The control: only a "target taken" index (`PathUniques.names/0`) is a
  # taken name. Any other changeset refusal stays the retryable create_failed.
  test "only a PathUniques constraint is a taken name" do
    taken = fn name ->
      %Ecto.Changeset{
        errors: [user_id: {"has already been taken", constraint: :unique, constraint_name: name}]
      }
      |> EngramWeb.CrdtChannel.path_taken?()
    end

    for name <- Engram.Notes.PathUniques.names(), do: assert(taken.(name), name)
    refute taken.("notes_pkey")
    refute EngramWeb.CrdtChannel.path_taken?(%Ecto.Changeset{errors: [path: {"is invalid", []}]})
  end
end
