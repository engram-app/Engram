defmodule Engram.Rebuild do
  @moduledoc """
  The one-time v5 index rebuild: its switch, the dry-run manifest and the
  spend ledger (chunker v5 plan, Task 16.1).

  ## The switch

  `INDEX_REBUILD` (`:index_rebuild`) is `off` (default), `dry_run` or `on`.

    * `off`: nothing here runs and nothing here is queried. The index
      version sweep rebuilds only notes older than the pinned versions
      (`target_versions/0`), which equal today's build versions, so main
      behaves exactly as before. A later stamp bump (PR-17) rebuilds nothing
      until the operator says so.
    * `dry_run`: `Engram.Workers.RebuildDryRun` plans every stale note and
      writes `rebuild_manifest` rows, the per-vault pinned `avgdl` and the
      ledger budget. No Voyage call, no Qdrant call. Version rebuilds stay
      gated as under `off`.
    * `on`: the version sweep targets the build's versions, every keyword
      encode reads the pinned `avgdl`, and spend is debited against the
      ledger. A debit past the budget halts the pass: `mode/0` then reads
      `:off` until a new budget is set (`set_budget/1` or a dry run). With
      no budget at all, `on` reads `:off` too.

  Resuming `on` after `off` needs nothing: the per-note version stamps say
  what is left.
  """

  import Ecto.Query

  alias Engram.Backfill.TenantScan
  alias Engram.Cache
  alias Engram.KeywordIndex
  alias Engram.Parsers.Markdown
  alias Engram.Rebuild.{Manifest, ManifestVault}
  alias Engram.Repo

  # The last versions every install rebuilds automatically, without the
  # switch: today's build (chunker 3, keyword 2). PR-17's bump to chunker 5
  # and keyword 3 waits for `on`. `:rebuild_pinned_versions` is a test seam
  # only (no env var): it lets a test build stand in for a bumped one.
  @pinned {3, 2}

  # Spec guards: the budget is 1.15x the manifest, and a note parks once it
  # costs over 1.5x its estimate AND over 50,000 tokens.
  @budget_pct 115
  @drift_pct 150
  @drift_floor 50_000

  @type mode :: :off | :dry_run | :on

  @spec mode() :: mode()
  def mode do
    case Engram.ServiceConfig.get(:index_rebuild, "off") do
      "dry_run" -> :dry_run
      "on" -> if halted?(), do: :off, else: :on
      _off -> :off
    end
  end

  @doc "`{chunker, keyword}` versions of this build."
  # No `@spec`: the body is two compile-time constants, so any integer spec
  # is a dialyzer `contract_supertype` (as `Repo.tenant_tables/0`).
  def build_versions, do: {Markdown.chunker_version(), KeywordIndex.version()}

  @doc """
  `{chunker, keyword}` versions the index version sweep rebuilds up to: the
  build's while `on`, else the pins (never above the build: a rollback build
  older than a pin keeps its own).
  """
  @spec target_versions() :: {pos_integer(), pos_integer()}
  def target_versions do
    {chunker, keyword} = build_versions()

    if mode() == :on do
      {chunker, keyword}
    else
      {pin_chunker, pin_keyword} = Engram.ServiceConfig.get(:rebuild_pinned_versions, @pinned)
      {min(chunker, pin_chunker), min(keyword, pin_keyword)}
    end
  end

  @doc """
  The vault's `avgdl` pinned by the dry run, or nil. Cached per node: every
  keyword encode reads it while `on`.
  """
  @spec pinned_avgdl(Ecto.UUID.t(), Ecto.UUID.t()) :: float() | nil
  def pinned_avgdl(user_id, vault_id) do
    Cache.fetch(:rebuild, {:avgdl, vault_id}, fn ->
      Repo.with_tenant!(user_id, fn ->
        from(v in ManifestVault, where: v.vault_id == ^vault_id, select: v.avgdl)
        |> Repo.one()
      end)
    end)
  end

  @doc """
  Records `tokens` the pass has spent, in one atomic statement. `:halt` once
  the total passes the budget (or with no budget at all); the halt is
  stamped in the same UPDATE, so concurrent debits never overspend unseen.
  """
  @spec debit(non_neg_integer()) :: :ok | :halt
  def debit(tokens) when is_integer(tokens) and tokens >= 0 do
    {_n, rows} =
      from(l in "rebuild_ledger",
        where: l.id == true,
        update: [
          inc: [spent_tokens: ^tokens],
          set: [
            # SET reads the OLD row: halts when this debit crosses the budget.
            halted_at:
              fragment(
                "CASE WHEN ? + ? > ? THEN coalesce(?, now()) ELSE ? END",
                l.spent_tokens,
                ^tokens,
                l.budget_tokens,
                l.halted_at,
                l.halted_at
              ),
            updated_at: fragment("now()")
          ]
        ],
        select: {l.spent_tokens, not is_nil(l.halted_at)}
      )
      |> Repo.update_all([])

    case rows do
      [{_spent, false}] -> :ok
      [{spent, true}] -> halt(spent)
      # No ledger row: no sealed budget, nothing may be spent.
      [] -> halt(0)
    end
  end

  defp halt(spent) do
    :telemetry.execute([:engram, :rebuild, :halted], %{spent_tokens: spent}, %{})
    :ok = Cache.evict(:rebuild, :halted)
    :halt
  end

  @doc """
  `{:park, :rebuild_drift}` when a note cost over 1.5x its manifest
  estimate and over 50,000 tokens. Takes the note (`id`, `user_id`), not
  just its id: the estimate is a tenant row. A note with no estimate counts
  as estimated at 0.
  """
  @spec check_note(%{id: Ecto.UUID.t(), user_id: Ecto.UUID.t()}, non_neg_integer()) ::
          :ok | {:park, :rebuild_drift}
  def check_note(_note, actual) when actual <= @drift_floor, do: :ok

  def check_note(%{id: note_id, user_id: user_id}, actual) do
    est =
      Repo.with_tenant!(user_id, fn ->
        from(m in Manifest, where: m.note_id == ^note_id, select: m.est_tokens)
        |> Repo.one()
      end) || 0

    if 100 * actual > @drift_pct * est, do: {:park, :rebuild_drift}, else: :ok
  end

  @doc "Upserts one user's manifest rows (`note_id`, `vault_id`, counts)."
  @spec put_manifest(Ecto.UUID.t(), [map()]) :: :ok
  def put_manifest(_user_id, []), do: :ok

  def put_manifest(user_id, rows) do
    rows = Enum.map(rows, &Map.put(&1, :user_id, user_id))

    {_, _} =
      Repo.with_tenant!(user_id, fn ->
        Repo.insert_all(Manifest, rows,
          on_conflict:
            {:replace,
             [:vault_id, :est_tokens, :new_points, :reused_points, :mean_pooled_points] ++
               [:dl_sum, :dl_count]},
          conflict_target: :note_id
        )
      end)

    :ok
  end

  @doc """
  Closes a dry run: pins each vault's `avgdl` from the manifest and sets the
  budget to 1.15x the manifest's estimated tokens. Per tenant, as
  `ReconcileEmbeddings` scans.
  """
  @spec seal() :: {:ok, non_neg_integer()}
  def seal do
    est =
      each_tenant(fn repo ->
        _ =
          repo.insert_all(
            ManifestVault,
            from(m in Manifest,
              where: m.dl_count > 0,
              group_by: [m.vault_id, m.user_id],
              select: %{
                vault_id: m.vault_id,
                user_id: m.user_id,
                avgdl: fragment("sum(?)::float8 / sum(?)", m.dl_sum, m.dl_count)
              }
            ),
            on_conflict: {:replace, [:avgdl]},
            conflict_target: :vault_id
          )

        from(m in Manifest, select: coalesce(sum(m.est_tokens), 0))
        |> repo.one()
        |> to_integer()
      end)
      |> Enum.sum()

    budget = div(@budget_pct * est + 99, 100)
    :ok = set_budget(budget)
    :ok = Cache.evict_all(:rebuild)
    {:ok, budget}
  end

  @doc "Sets the pass budget and clears a halt; what was spent stays."
  @spec set_budget(non_neg_integer()) :: :ok
  def set_budget(tokens) when is_integer(tokens) and tokens >= 0 do
    {1, _} =
      Repo.insert_all(
        "rebuild_ledger",
        [%{id: true, budget_tokens: tokens, spent_tokens: 0}],
        on_conflict: [
          set: [budget_tokens: tokens, halted_at: nil, updated_at: DateTime.utc_now()]
        ],
        conflict_target: :id
      )

    Cache.evict(:rebuild, :halted)
  end

  @doc "The ledger, or nil before any budget was set."
  @spec ledger() ::
          %{budget_tokens: integer(), spent_tokens: integer(), halted?: boolean()} | nil
  def ledger do
    from(l in "rebuild_ledger",
      select: %{
        budget_tokens: l.budget_tokens,
        spent_tokens: l.spent_tokens,
        halted?: not is_nil(l.halted_at)
      }
    )
    |> Repo.one()
  end

  # No ledger row is halted too: `on` without a sealed budget spends nothing.
  defp halted? do
    Cache.fetch(:rebuild, :halted, fn ->
      from(l in "rebuild_ledger", select: is_nil(l.halted_at)) |> Repo.one() != true
    end)
  end

  @doc false
  # `fun.(repo)` once on the maintenance pool where configured (it sees every
  # tenant), else once per user inside that user's tenant. See
  # `ReconcileEmbeddings.scan/3` for why never cross-tenant on the app pool.
  @spec each_tenant((module() -> term())) :: [term()]
  def each_tenant(fun) do
    case Repo.maintenance() do
      Repo -> Enum.map(TenantScan.user_ids(), &Repo.with_tenant!(&1, fn -> fun.(Repo) end))
      maintenance -> [fun.(maintenance)]
    end
  end

  defp to_integer(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_integer(n) when is_integer(n), do: n
end
