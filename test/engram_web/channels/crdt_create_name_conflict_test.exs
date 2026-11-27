defmodule EngramWeb.CrdtCreateNameConflictTest do
  # A crdt_create at a path whose folder row and name another live note holds
  # (`notes_name_live`, a stale name key) is a taken name, never a crashed
  # channel or a re-mint. A client that handles a taken name (caps=name_taken,
  # plugin or web bundle) gets `id_conflict`; anything else keeps
  # `create_failed`, as for a path index refusal: a released plugin drops an
  # `id_conflict` create silently, and an older web bundle name-bumps only on
  # `create_failed`.
  use EngramWeb.ChannelCase, async: false

  import ExUnit.CaptureLog

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

  for {label, kind, want} <- [
        {"an old plugin gets create_failed", :old, "create_failed"},
        {"a caps=name_taken plugin gets id_conflict", :caps, "id_conflict"},
        {"an old web bundle (no caps) gets create_failed", :web, "create_failed"},
        {"a caps=name_taken web bundle gets id_conflict", :web_caps, "id_conflict"}
      ] do
    test "crdt_create at a notes_name_live holder: #{label}", %{user: user, vault: vault} do
      assigns = %{
        current_user: user,
        current_api_key: nil,
        name_taken_terminal: unquote(kind) in [:caps, :web_caps]
      }

      params =
        if unquote(kind) in [:web, :web_caps],
          do: %{"crdt_proto" => 2, "client_type" => "web"},
          else: %{"crdt_proto" => 2}

      {:ok, _, socket} =
        subscribe_and_join(
          socket(EngramWeb.UserSocket, "user_#{user.id}", assigns),
          EngramWeb.CrdtChannel,
          "crdt:#{user.id}:#{vault.id}",
          params
        )

      Sandbox.allow(Repo, self(), socket.channel_pid)

      # The refusing index is logged on every reply, so stale name keys show.
      log =
        capture_log(fn ->
          ref =
            push(socket, "crdt_create", %{"doc_id" => Ecto.UUID.generate(), "path" => "F/x.md"})

          assert_reply ref, :error, %{reason: unquote(want)}
        end)

      assert log =~ "notes_name_live"
      refute log =~ "F/x.md"
    end
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
