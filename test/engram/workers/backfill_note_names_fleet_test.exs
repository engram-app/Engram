defmodule Engram.Workers.BackfillNoteNamesFleetTest do
  @moduledoc """
  The `NoteName` chain's fleet walk (SaaS): through the maintenance pool,
  connected as the real `engram_maintenance` role (no SUPERUSER, no
  BYPASSRLS), `user_id: nil`, across two tenants in one walk. A missing grant
  or policy turns this red. Fixtures are COMMITTED (the pool is a second
  connection) and removed on exit. Also the lock rule: a row another
  transaction holds is skipped, never waited on (review F3).
  """
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Crypto
  alias Engram.Notes.Name
  alias Engram.Repo
  alias Engram.Repo.Maintenance
  alias Engram.Workers.BackfillNoteNames

  setup do
    config =
      Keyword.merge(Repo.config(),
        pool: DBConnection.ConnectionPool,
        pool_size: 1,
        after_connect: {Postgrex, :query!, ["SET SESSION AUTHORIZATION engram_maintenance", []]}
      )

    start_supervised!({Maintenance, config})
    Application.put_env(:engram, :maintenance_repo_enabled, true)
    on_exit(fn -> Application.delete_env(:engram, :maintenance_repo_enabled) end)

    # Committed fixtures commit their side effects too: the writes enqueue
    # Oban jobs outside the sandbox. Every job past this id is ours and goes
    # on exit, or later tests in the partition (the queue-depth poll's) see it.
    jobs_before =
      Sandbox.unboxed_run(Repo, fn ->
        Repo.one(from(j in Oban.Job, select: max(j.id))) || 0
      end)

    made =
      Sandbox.unboxed_run(Repo, fn ->
        for i <- 1..2 do
          {:ok, user} = Crypto.ensure_user_dek(insert(:user))
          insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
          {:ok, vault, _} = Engram.Vaults.register_vault(user, "Fleet#{i}", Ecto.UUID.generate())

          {:ok, note} =
            Engram.Notes.upsert_note(
              user,
              vault,
              # Root level on purpose: no folder rows, so the on-exit vault
              # delete runs no folder RI action on a shared pool backend
              # (docs/context/testing-strategy.md, plan tests).
              %{"path" => "n#{i}.md", "content" => "# T\n\nbody"},
              actor: "api"
            )

          Repo.query!(
            "UPDATE notes SET name_ciphertext = NULL, name_nonce = NULL, name_hmac = NULL, " <>
              "name_ci_hmac = NULL, name_stamp = NULL WHERE id = $1",
            [Ecto.UUID.dump!(note.id)]
          )

          {user, note}
        end
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        for {user, _} <- made do
          Repo.delete_all(from(v in Engram.Vaults.Vault, where: v.user_id == ^user.id),
            skip_tenant_check: true
          )

          Repo.delete!(user, skip_tenant_check: true)
        end

        Repo.query!("DELETE FROM data_migrations WHERE name = 'note_name'")
        Repo.delete_all(from(j in Oban.Job, where: j.id > ^jobs_before))
      end)
    end)

    %{made: made}
  end

  defp name_of({user, note}) do
    {:ok, dek} = Crypto.get_dek(user)

    Sandbox.unboxed_run(Repo, fn ->
      %{rows: [[ct, nonce, stamp, path_nonce]]} =
        Repo.query!(
          "SELECT name_ciphertext, name_nonce, name_stamp, path_nonce FROM notes WHERE id = $1",
          [Ecto.UUID.dump!(note.id)]
        )

      cond do
        is_nil(ct) -> nil
        stamp != Name.stamp(path_nonce) -> :stale
        true -> elem(Name.decrypt(:notes, dek, note.id, ct, nonce), 1)
      end
    end)
  end

  test "one fleet window heals every tenant's rows on the maintenance pool", %{made: made} do
    ids = Enum.map(made, fn {_user, note} -> note.id end)

    assert {2, false} =
             BackfillNoteNames.heal_window(:notes, ids, %{repo: Maintenance, user_id: nil})

    assert Enum.map(made, &name_of/1) == ["n1.md", "n2.md"]
  end

  test "a row another transaction holds is skipped and counted as left, not waited on", %{
    made: [held, free] = made
  } do
    test_pid = self()
    {_user, held_note} = held

    locker =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT 1 FROM notes WHERE id = $1 FOR UPDATE", [
              Ecto.UUID.dump!(held_note.id)
            ])

            send(test_pid, :locked)

            receive do
              :release -> :ok
            end
          end)
        end)
      end)

    assert_receive :locked, 5_000
    ids = Enum.map(made, fn {_user, note} -> note.id end)
    started = System.monotonic_time(:millisecond)

    assert {1, true} =
             BackfillNoteNames.heal_window(:notes, ids, %{repo: Maintenance, user_id: nil})

    # Well under the 2 s lock_timeout: it never waited on the held row.
    assert System.monotonic_time(:millisecond) - started < 1_500

    send(locker.pid, :release)
    Task.await(locker)

    assert name_of(held) == nil
    assert name_of(free) == "n2.md"
  end
end
