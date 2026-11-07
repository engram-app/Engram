defmodule Engram.DataMigrations.NameTerms do
  @moduledoc """
  Backfill of `name_terms` (O(1) folder rename plan, S1;
  `Engram.Search.NameTerms`): every live note and folder whose terms were
  not written for its current name (the `notes_name_terms_stale` /
  `folders_name_terms_stale` predicate: never written, written under an
  older stamp version, renamed or rotated since, restored).

  A pass does no healing itself. It starts the paced chain
  (`Engram.Workers.BackfillNameTerms`) when none is in flight and a stale
  ref exists, and is done when no chain is in flight and no stale ref is
  left: one `LIMIT 1` probe per table, served by the stale partial indexes
  (O(1) in the table, empty in steady state).

  The search leg does NOT wait for this ledger: a ref without terms is only
  not found by the leg yet. After done, a previous-release writer's drift is
  healed by `Engram.Bookkeeping.Drain` through the same indexes
  (`run_pass(user_ids: ...)`). Zero operator steps; not re-verified.

  Kill switch `enabled?/0` = service override `name_terms_backfill`,
  default on.
  """
  @behaviour Engram.DataMigration

  import Ecto.Query, only: [from: 2]

  alias Engram.Backfill.TenantScan
  alias Engram.DataMigrations
  alias Engram.Folders.Folder
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Search.NameTerms
  alias Engram.Workers.BackfillNameTerms

  @impl true
  def name, do: "name_terms"

  @impl true
  def version, do: NameTerms.version()

  @impl true
  def enabled?, do: Engram.ServiceConfig.get(:name_terms_backfill, true) == true

  @doc "True once every live note and folder has current terms."
  def done?, do: DataMigrations.done?(name(), version())

  @impl true
  def run_pass, do: run_pass([])

  @doc false
  # `user_ids:` heals those users inline (the drain's repair).
  def run_pass(opts) do
    case Keyword.fetch(opts, :user_ids) do
      {:ok, user_ids} ->
        fixed =
          for user_id <- user_ids, schema <- [Note, Folder], reduce: 0 do
            n -> n + NameTerms.heal_user(schema, user_id)
          end

        if fixed == 0, do: :done, else: {:more, rows: fixed}

      :error ->
        chain()
    end
  end

  defp chain do
    cond do
      DataMigrations.jobs_in_flight?(BackfillNameTerms) ->
        {:more, chain: 1}

      stale?() ->
        {:ok, _} = Oban.insert(BackfillNameTerms.start())
        {:more, chain: 1}

      true ->
        :done
    end
  end

  # One `LIMIT 1` probe per table on its stale partial index.
  defp stale?, do: Enum.any?([Note, Folder], &stale?/1)

  defp stale?(schema) do
    probe = fn repo, query -> repo.exists?(query) end
    query = NameTerms.stale_query(schema)

    case TenantScan.pool() do
      {:fleet, repo} ->
        probe.(repo, query)

      :per_user ->
        TenantScan.user_ids()
        |> Enum.any?(fn uid ->
          {:ok, found?} =
            Repo.with_tenant(uid, fn ->
              probe.(Repo, from(r in query, where: r.user_id == ^uid))
            end)

          found?
        end)
    end
  end
end
