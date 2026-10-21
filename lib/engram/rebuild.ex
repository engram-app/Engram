defmodule Engram.Rebuild do
  @moduledoc """
  The one-time v5 index rebuild: its switch, the dry-run manifest and the
  spend ledger (chunker v5 plan, Task 16.1).

  ## The switch

  `INDEX_REBUILD` (`:index_rebuild`) is `off` (default), `dry_run` or `on`.

    * `off`: nothing here runs and nothing here is queried. Every index
      version check (`target_versions/0`) uses the pinned versions, which
      equal today's build, so main behaves exactly as before. A later stamp
      bump (PR-17) rebuilds nothing until the operator says so.
    * `dry_run`: `Engram.Workers.RebuildDryRun` plans every stale note into
      `rebuild_manifest`, then seals: the per-vault pinned `avgdl` and the
      ledger budget. No Voyage call, no Qdrant call. Version rebuilds stay
      gated as under `off`.
    * `on`: version checks target the build's versions, every keyword encode
      reads the pinned `avgdl`, and every version rebuild's Voyage tokens are
      debited against the ledger (`spend/2`). A debit past the budget halts
      the pass: `mode/0` then reads `:off`, so queued rebuilds skip, until an
      operator sets a new budget (`set_budget/1`). With no budget at all,
      `on` reads `:off` too.

  Resuming `on` after `off` needs nothing: the per-note version stamps say
  what is left.
  """

  import Ecto.Query

  alias Engram.Backfill.TenantScan
  alias Engram.Cache
  alias Engram.KeywordIndex
  alias Engram.Logger.Metadata
  alias Engram.Notes.Note
  alias Engram.Parsers.Markdown
  alias Engram.Rebuild.{Manifest, ManifestVault}
  alias Engram.Repo

  require Logger

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

  @meter_key {__MODULE__, :tokens}

  @type mode :: :off | :dry_run | :on
  # A note or any map naming one and its owner (a `%Note{}` qualifies).
  @type note_ref :: %{
          required(:id) => Ecto.UUID.t(),
          required(:user_id) => Ecto.UUID.t(),
          optional(atom()) => any()
        }

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
  `{chunker, keyword}` versions every index version check rebuilds up to:
  the build's while `on`, else the pins (never above the build: a rollback
  build older than a pin keeps its own). The ONE accessor: the reconcile
  sweep, `EmbedNote.version_stale?/1`, `RefreshKeywordVectors` and
  `IndexVersions` all read it.
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
  `[:engram, :rebuild, :halted]` fires once, on the debit that halts.
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
        # PG18 `RETURNING old.*`: halted now and not before is the off
        # transition, seen by exactly one debit.
        select: {l.spent_tokens, not is_nil(l.halted_at), fragment("old.halted_at IS NULL")}
      )
      |> Repo.update_all([])

    case rows do
      [{_spent, false, _}] ->
        :ok

      [{spent, true, transition?}] ->
        if transition? == true do
          :telemetry.execute([:engram, :rebuild, :halted], %{count: 1, spent_tokens: spent}, %{})
          :ok = Cache.evict(:rebuild, :halted)
        end

        :halt

      # No ledger row: no sealed budget, nothing may be spent.
      [] ->
        :halt
    end
  end

  @doc """
  Runs one version rebuild's indexing `fun` and charges what it sent Voyage
  (`usage.total_tokens`, counted from `[:engram, :voyage, :embed, :tokens]`
  in this process) to the ledger, raise or not. Then the drift check: a
  note that cost over its limit is parked until edited.
  """
  @spec spend(Note.t(), (-> result)) :: result when result: term()
  def spend(%Note{} = note, fun) do
    Process.put(@meter_key, 0)

    try do
      fun.()
    after
      tokens = Process.delete(@meter_key) || 0
      _ = if tokens > 0, do: debit(tokens)
      if check_note(note, tokens) != :ok, do: park_drift(note, tokens)
    end
  end

  @doc false
  # Attached once at boot. Telemetry handlers run in the emitting process,
  # so this counts only the tokens of the process inside `spend/2`.
  def attach do
    :telemetry.attach(
      "engram-rebuild-token-meter",
      [:engram, :voyage, :embed, :tokens],
      &__MODULE__.handle_tokens/4,
      nil
    )
  end

  @doc false
  def handle_tokens(_event, %{total_tokens: tokens}, _meta, _config) when is_integer(tokens) do
    case Process.get(@meter_key) do
      nil -> :ok
      n -> Process.put(@meter_key, n + tokens)
    end

    :ok
  end

  def handle_tokens(_event, _measurements, _meta, _config), do: :ok

  @doc """
  `{:park, :rebuild_drift}` when a note cost over 1.5x its manifest
  estimate and over 50,000 tokens. Takes the note (`id`, `user_id`), not
  just its id: the estimate is a tenant row. A note with no estimate counts
  as estimated at 0.
  """
  @spec check_note(note_ref(), non_neg_integer()) :: :ok | {:park, :rebuild_drift}
  def check_note(_note, actual) when actual <= @drift_floor, do: :ok

  def check_note(%{id: note_id, user_id: user_id}, actual) do
    est =
      Repo.with_tenant!(user_id, fn ->
        from(m in Manifest, where: m.note_id == ^note_id, select: m.est_tokens)
        |> Repo.one()
      end) || 0

    if 100 * actual > @drift_pct * est, do: {:park, :rebuild_drift}, else: :ok
  end

  # Parked like a too-long note: until its content changes. Tokens only in
  # the log: they are counts, not content.
  defp park_drift(note, tokens) do
    {:ok, _} =
      Repo.with_tenant(note.user_id, fn ->
        Repo.update_all(from(n in Note, where: n.kind == "note" and n.id == ^note.id),
          set: [embed_retry_after: Engram.Workers.EmbedNote.parked_until_edited()]
        )
      end)

    :telemetry.execute([:engram, :rebuild, :drift_parked], %{count: 1, tokens: tokens}, %{})

    Logger.warning(
      "rebuild_drift_parked",
      Metadata.with_category(:warning, :oban, note_id: note.id, total_count: tokens)
    )
  end

  @doc "Upserts one user's planned manifest rows (`note_id`, `vault_id`, counts)."
  @spec put_manifest(Ecto.UUID.t(), [map()]) :: :ok
  def put_manifest(_user_id, []), do: :ok

  def put_manifest(user_id, rows) do
    now = DateTime.utc_now()
    rows = Enum.map(rows, &Map.merge(&1, %{user_id: user_id, planned_at: now}))
    upsert(user_id, rows)
  end

  @doc """
  The planner's dead-man row: written right before a note is planned, and
  replaced by `put_manifest/2` when it is. One still pending (`planned_at`
  nil) on a later run is a note whose planning crashed the node: the dry run
  never plans it again and counts it as skipped.
  """
  @spec put_pending(Ecto.UUID.t(), %{
          required(:id) => Ecto.UUID.t(),
          required(:vault_id) => Ecto.UUID.t(),
          optional(atom()) => any()
        }) :: :ok
  def put_pending(user_id, note) do
    upsert(user_id, [
      %{
        note_id: note.id,
        vault_id: note.vault_id,
        user_id: user_id,
        est_tokens: 0,
        new_points: 0,
        reused_points: 0,
        mean_pooled_points: 0,
        dl_sum: 0,
        dl_count: 0,
        planned_at: nil
      }
    ])
  end

  defp upsert(user_id, rows) do
    {_, _} =
      Repo.with_tenant!(user_id, fn ->
        Repo.insert_all(Manifest, rows,
          on_conflict:
            {:replace,
             [:vault_id, :est_tokens, :new_points, :reused_points, :mean_pooled_points] ++
               [:dl_sum, :dl_count, :planned_at]},
          conflict_target: :note_id
        )
      end)

    :ok
  end

  @doc """
  Closes a dry run: pins each vault's `avgdl` from the manifest and sets the
  budget to 1.15x the manifest's estimated tokens. Only while the mode is
  still `dry_run`. The budget is set only when none exists (an operator's
  budget wins, and a halt is never cleared here), and once a budget exists
  the pins are never replaced, only added for vaults that had none, so a
  late seal cannot move a running pass's avgdl. Per tenant, as
  `ReconcileEmbeddings` scans.
  """
  @spec seal() :: {:ok, non_neg_integer()} | {:error, :not_dry_run}
  def seal do
    if mode() == :dry_run, do: do_seal(), else: {:error, :not_dry_run}
  end

  defp do_seal do
    pins_conflict =
      if ledger() == nil,
        do: {:replace, [:avgdl]},
        else: :nothing

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
            on_conflict: pins_conflict,
            conflict_target: :vault_id
          )

        from(m in Manifest, select: coalesce(sum(m.est_tokens), 0))
        |> repo.one()
        |> to_integer()
      end)
      |> Enum.sum()

    budget = div(@budget_pct * est + 99, 100)

    {_, _} =
      Repo.insert_all("rebuild_ledger", [%{id: true, budget_tokens: budget, spent_tokens: 0}],
        on_conflict: :nothing,
        conflict_target: :id
      )

    :ok = Cache.evict_all(:rebuild)
    {:ok, ledger().budget_tokens}
  end

  @doc """
  The operator's lever: sets the pass budget and clears a halt; what was
  spent stays. Never called by the pass itself.
  """
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
      where: l.id == true,
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
      from(l in "rebuild_ledger", where: l.id == true, select: is_nil(l.halted_at))
      |> Repo.one() != true
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
