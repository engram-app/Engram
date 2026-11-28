defmodule EngramWeb.CrdtCreateResurrectTakenTest do
  # A crdt_create that revives a tombstoned id onto a path another live note
  # holds is refused exactly as a path-taken create is, never a crashed
  # channel. The unique violation used to abort the tenant
  # transaction, so the next statement raised 25P02 instead.
  use EngramWeb.ChannelCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Notes.Note

  setup do
    EngramWeb.RateLimiter.reset_buckets!()
    on_exit(fn -> EngramWeb.RateLimiter.reset_buckets!() end)

    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    {:ok, vault, _} = Vaults.register_vault(user, "ResurrectTaken", Ecto.UUID.generate())
    %{user: user, vault: vault, a: tombstone!(user, vault, "P.md")}
  end

  # Note A, deleted at `path` and aged past the delete-wins window, so a
  # revive at its own path is a resurrect, not a `recently_deleted` refusal.
  defp tombstone!(user, vault, path) do
    {:ok, a} = Notes.upsert_note(user, vault, %{"path" => path, "content" => "a"}, actor: "api")
    :ok = Notes.delete_note(user, vault, path)
    aged = DateTime.add(DateTime.utc_now(), -3600, :second)

    {1, _} =
      from(n in Note, where: n.id == ^a.id)
      |> Repo.update_all([set: [deleted_at: aged]], skip_tenant_check: true)

    a
  end

  defp join!(user, vault) do
    {:ok, _, socket} =
      subscribe_and_join(
        user_socket(user),
        EngramWeb.CrdtChannel,
        "crdt:#{user.id}:#{vault.id}",
        %{"crdt_proto" => 2}
      )

    Sandbox.allow(Repo, self(), socket.channel_pid)
    socket
  end

  # The reason the wire gives a create refused because the path is taken,
  # read from the existing path-taken refusal (a fresh id at a stale name key,
  # `crdt_create_name_conflict_test.exs`) instead of hardcoded, so this holds
  # whatever that shared mapping replies.
  defp path_taken_reason(socket, user, vault) do
    {:ok, holder} =
      Notes.upsert_note(user, vault, %{"path" => "F/a.md", "content" => "a"}, actor: "api")

    Engram.Fixtures.stale_name_holder!(user, vault, holder, "F/x.md")

    capture_log(fn ->
      ref = push(socket, "crdt_create", %{"doc_id" => Ecto.UUID.generate(), "path" => "F/x.md"})
      assert_reply ref, :error, %{reason: reason}
      send(self(), {:reason, reason})
    end)

    assert_received {:reason, reason}
    reason
  end

  test "reviving A onto a path live note B holds is the path-taken refusal", %{
    user: user,
    vault: vault,
    a: a
  } do
    {:ok, b} = Notes.genesis_crdt_note(user, vault, Ecto.UUID.generate(), "P.md")
    assert b.id != a.id

    socket = join!(user, vault)
    expected = path_taken_reason(socket, user, vault)

    log =
      capture_log(fn ->
        ref = push(socket, "crdt_create", %{"doc_id" => a.id, "path" => "P.md"})
        assert_reply ref, :error, %{reason: reason}
        send(self(), {:reason, reason})
      end)

    assert_received {:reason, ^expected}
    refute log =~ "25P02"

    # The channel survived and B still owns the path; A stays deleted.
    assert Process.alive?(socket.channel_pid)
    assert {:ok, %{id: b_id}} = Notes.get_note(user, vault, "P.md")
    assert b_id == b.id
    assert Repo.get!(Note, a.id, skip_tenant_check: true).deleted_at
  end

  test "reviving A onto a FREE path still resurrects it", %{user: user, vault: vault, a: a} do
    socket = join!(user, vault)
    ref = push(socket, "crdt_create", %{"doc_id" => a.id, "path" => "Free.md"})
    assert_reply ref, :ok, %{doc_id: doc_id}
    assert doc_id == a.id

    assert {:ok, %{id: ^doc_id}} = Notes.get_note(user, vault, "Free.md")
    refute Repo.get!(Note, a.id, skip_tenant_check: true).deleted_at
  end
end
