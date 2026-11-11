defmodule Engram.Workers.BackfillNameTermsFleetTest do
  @moduledoc """
  One full `NameTerms` chain hop on the fleet path prod takes: the
  maintenance pool configured, connected as `engram_maintenance`, committed
  fixtures in two tenants. The rest of the suite runs the per-user pool, so
  this is the only test that runs the fleet walk, the heal and the pass line
  (`Ledger.left/0`) end to end. Red before the fix: `left/0`'s
  `subquery(... select: 1)` raised Ecto.SubQueryError after the hop
  committed, so every prod hop failed.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Backfill.TenantScan
  alias Engram.Crypto
  alias Engram.Repo
  alias Engram.Search.NameTerms.Row
  alias Engram.Test.LogCapture
  alias Engram.Workers.BackfillNameTerms

  setup do
    Engram.Test.MaintenancePool.start!()

    jobs_before =
      Sandbox.unboxed_run(Repo, fn ->
        Repo.one(from(j in Oban.Job, select: max(j.id))) || 0
      end)

    made =
      Sandbox.unboxed_run(Repo, fn ->
        for i <- 1..2 do
          {:ok, user} = Crypto.ensure_user_dek(insert(:user))
          insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
          {:ok, vault, _} = Engram.Vaults.register_vault(user, "Terms#{i}", Ecto.UUID.generate())

          # Root level: no folder rows, so the on-exit vault delete runs no
          # folder RI action on the shared pool backend.
          {:ok, note} =
            Engram.Notes.upsert_note(
              user,
              vault,
              %{"path" => "fleet#{i}.md", "content" => "# T\n\nbody"},
              actor: "api"
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

        Repo.delete_all(from(j in Oban.Job, where: j.id > ^jobs_before))
      end)
    end)

    %{made: made}
  end

  defp rows(note_id) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.all(from(r in Row, where: r.ref_id == ^note_id), skip_tenant_check: true)
    end)
  end

  test "a hop heals every tenant's refs and logs its pass line with a counted left", %{
    made: made
  } do
    assert {:fleet, _} = TenantScan.pool()
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)

    {result, events} =
      LogCapture.with_events(fn ->
        perform_job(BackfillNameTerms, %{"table" => "notes", "pause_ms" => 0})
      end)

    assert result == :ok
    assert Enum.all?(made, fn {_user, note} -> rows(note.id) != [] end)

    assert [meta] =
             for(
               %{msg: {:string, msg}, meta: meta} <- events,
               IO.iodata_to_binary(msg) == "backfill pass",
               do: meta
             )

    assert %{backfill: "name_terms", held: :none} = meta
    assert is_integer(meta.left)
  end
end
