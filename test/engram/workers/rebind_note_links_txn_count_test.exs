defmodule Engram.Workers.RebindNoteLinksTxnCountTest do
  # Budget: ONE tenant transaction (vault read + rebind) and ONE users read
  # (rotation gate + DEK) per RebindNoteLinks job. Was 2 and 2.
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Links
  alias Engram.Repo
  alias Engram.TenantQueryCounter
  alias Engram.Workers.RebindNoteLinks

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    source = Engram.Fixtures.insert_note!(user, vault, %{path: "S.md"})

    :ok =
      Links.replace_links(user, vault, source.id, [
        %{target: "Later", alias: nil, anchor: nil, link_type: "wikilink", position: 0}
      ])

    target = Engram.Fixtures.insert_note!(user, vault, %{path: "Later.md"})

    args = %{
      user_id: user.id,
      vault_id: vault.id,
      basename_hmac: Base.encode64(Links.basename_hmac(user, "later"))
    }

    %{user: user, source: source, target: target, args: args}
  end

  test "one tenant transaction and one users read per job",
       %{user: user, source: source, target: target, args: args} do
    test_pid = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:engram, :repo, :query],
      fn _e, _m, meta, _c ->
        if meta[:source] == "users" and self() == test_pid, do: send(test_pid, :users_read)
      end,
      nil
    )

    enters =
      try do
        TenantQueryCounter.count_tenant_enters(fn ->
          assert :ok = perform_job(RebindNoteLinks, args)
        end)
      after
        :telemetry.detach(handler)
      end

    assert length(enters) == 1,
           "RebindNoteLinks opened #{length(enters)} tenant transactions, budget is 1"

    assert users_reads() == 1
    assert [%{target_note_id: tid}] = Links.links_for_note(user, source.id)
    assert tid == target.id
  end

  test "the rotation gate still reads live state", %{user: user, args: args} do
    Repo.update_all(
      from(u in User, where: u.id == ^user.id),
      [set: [dek_rotation_locked_at: DateTime.utc_now()]],
      skip_tenant_check: true
    )

    assert {:snooze, 60} = perform_job(RebindNoteLinks, args)
  end

  test "a missing vault discards", %{args: args} do
    assert {:discard, _} = perform_job(RebindNoteLinks, %{args | vault_id: Ecto.UUID.generate()})
  end

  test "a missing user discards", %{args: args} do
    assert {:discard, :user_deleted} =
             perform_job(RebindNoteLinks, %{args | user_id: Ecto.UUID.generate()})
  end

  defp users_reads(n \\ 0) do
    receive do
      :users_read -> users_reads(n + 1)
    after
      0 -> n
    end
  end
end
