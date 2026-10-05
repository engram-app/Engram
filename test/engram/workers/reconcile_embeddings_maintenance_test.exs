defmodule Engram.Workers.ReconcileEmbeddingsMaintenanceTest do
  @moduledoc """
  Proves `ReconcileEmbeddings` sweeps every tenant in ONE pass on the
  maintenance pool when one is configured, instead of one transaction per
  user (O(users) per tick).

  The app pool is dropped to `engram_app` with no tenant, where the notes
  policy hides every row, while a real maintenance pool runs on its own
  connection. Only a sweep that reads through that pool finds the notes. The
  rows are COMMITTED so the second connection sees them, and deleted on exit.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query
  import Engram.RlsCase

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Repo.Maintenance
  alias Engram.Workers.{EmbedNote, ReconcileEmbeddings}

  setup do
    config = Keyword.merge(Repo.config(), pool: DBConnection.ConnectionPool, pool_size: 1)
    start_supervised!({Maintenance, config})
    Application.put_env(:engram, :maintenance_repo_enabled, true)
    on_exit(fn -> Application.delete_env(:engram, :maintenance_repo_enabled) end)

    {users, notes} =
      Sandbox.unboxed_run(Repo, fn ->
        for i <- 1..2, reduce: {[], []} do
          {users, notes} ->
            user = insert(:user)
            vault = insert(:vault, user: user)

            note =
              Engram.Fixtures.insert_note!(user, vault,
                path: "n#{i}.md",
                content: "# N#{i}",
                embed_hash: nil
              )

            {[user | users], [note | notes]}
        end
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        # notes do not cascade from users.
        ids = Enum.map(users, & &1.id)
        Repo.delete_all(from(n in Note, where: n.user_id in ^ids), skip_tenant_check: true)
        for u <- users, do: Repo.delete!(u, skip_tenant_check: true)
      end)
    end)

    %{notes: notes}
  end

  test "finds every tenant's stale notes through the maintenance pool", %{notes: notes} do
    # CONTROL: the app pool, as it runs here, sees none of them.
    assert {:returned, 0} =
             as_prod_role(fn -> Repo.aggregate(Note, :count, skip_tenant_check: true) end)

    # The per-tenant fallback would also find them (it sets each tenant on
    # the app pool), so what tells the two apart: no `notes` query on Repo.
    test_pid = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:engram, :repo, :query],
      # The maintenance pool shares this telemetry prefix (same config): tell
      # them apart by repo.
      fn _e, _m, %{source: source, repo: repo}, _c ->
        if source == "notes" and repo == Repo and self() == test_pid,
          do: send(test_pid, :app_pool_notes_query)
      end,
      nil
    )

    try do
      assert :ok = as_prod_role_committing(fn -> perform_job(ReconcileEmbeddings, %{}) end)
    after
      :telemetry.detach(handler)
    end

    refute_received :app_pool_notes_query
    for note <- notes, do: assert_enqueued(worker: EmbedNote, args: %{"note_id" => note.id})
  end
end
