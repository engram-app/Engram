defmodule Engram.Workers.BackfillNoteLinkQualifiedFleetTest do
  @moduledoc """
  The `NoteLinkQualified` chain's fleet walk (SaaS): through the maintenance
  pool, connected as the real `engram_maintenance` role (no SUPERUSER, no
  BYPASSRLS), `user_id: nil`, across two tenants in one walk. A missing grant
  or policy turns this red. Fixtures are COMMITTED (the pool is a second
  connection) and removed on exit.
  """
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Crypto
  alias Engram.Links
  alias Engram.Links.Parser
  alias Engram.Repo
  alias Engram.Repo.Maintenance
  alias Engram.Workers.BackfillNoteLinkQualified

  setup do
    Engram.Test.MaintenancePool.start!()

    jobs_before =
      Sandbox.unboxed_run(Repo, fn -> Repo.one(from(j in Oban.Job, select: max(j.id))) || 0 end)

    made =
      Sandbox.unboxed_run(Repo, fn ->
        for {i, content} <- [{1, "[[Bare]] [[F/Q]]"}, {2, "[[../Up]]"}] do
          {:ok, user} = Crypto.ensure_user_dek(insert(:user))
          insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
          {:ok, vault, _} = Engram.Vaults.register_vault(user, "Fleet#{i}", Ecto.UUID.generate())

          # Root level on purpose: no folder rows, so the on-exit vault delete
          # runs no folder RI action on a shared pool backend.
          {:ok, note} =
            Engram.Notes.upsert_note(user, vault, %{"path" => "n#{i}.md", "content" => "x"},
              actor: "api"
            )

          :ok = Links.replace_links(user, vault, note.id, Parser.extract(content))

          Repo.query!("UPDATE note_links SET qualified = NULL WHERE source_note_id = $1", [
            Ecto.UUID.dump!(note.id)
          ])

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

        Repo.query!("DELETE FROM data_migrations WHERE name = 'note_link_qualified'")
        Repo.delete_all(from(j in Oban.Job, where: j.id > ^jobs_before))
      end)
    end)

    %{made: made}
  end

  defp qualified({_user, note}) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!(
        "SELECT qualified FROM note_links WHERE source_note_id = $1 ORDER BY position",
        [Ecto.UUID.dump!(note.id)]
      ).rows
      |> List.flatten()
    end)
  end

  test "one fleet window heals every tenant's rows on the maintenance pool", %{made: made} do
    ids =
      Sandbox.unboxed_run(Repo, fn ->
        note_ids = Enum.map(made, fn {_u, n} -> Ecto.UUID.dump!(n.id) end)

        Repo.query!("SELECT id::text FROM note_links WHERE source_note_id = ANY($1)", [note_ids]).rows
        |> List.flatten()
      end)

    assert {3, false} =
             BackfillNoteLinkQualified.heal_window(ids, %{repo: Maintenance, user_id: nil})

    assert Enum.map(made, &qualified/1) == [[false, true], [true]]
  end

  test "one full hop on the fleet path classifies every tenant's rows", %{made: made} do
    assert {:fleet, _} = Engram.Backfill.TenantScan.pool()
    assert {:next, _} = BackfillNoteLinkQualified.hop(%{}, pause_ms: 0)
    assert Enum.map(made, &qualified/1) == [[false, true], [true]]
  end
end
