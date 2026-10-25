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

  Resuming is `on` plus a budget (`set_budget/1`) plus
  `Engram.Workers.ReconcileEmbeddings.kick/0`: the per-note version stamps
  say what is left, and the kick queues it within about a minute. The jobs
  a halted pass skipped released their notes' sweep backoff
  (`Engram.Workers.RebuildStaleNote`), and one caught mid-flight retries
  after 60 s. Without the kick the 5-minute cron picks the notes up.

  ## Pricing by plan

  The manifest records each note's plan doc model (`Engram.EmbedModels`),
  and the budget and every debit count cost in voyage-4-large tokens: a
  Free note's voyage-4-lite tokens weigh a sixth (`EmbedModels.large_tokens/2`).
  So `budget_tokens` times $0.12/M is the pass's budget in dollars. The
  drift park and the token bucket count raw tokens.

  ## The v5 layout guard (Task 16.4)

  `on` reads `:on` only while new points are written in the v5 layout
  (`Qdrant.write_v5_layout?/0`, which implies `:v5_payload_format`), and a
  dry run seals only then. Otherwise `on` reads `:off` and logs one warning
  per node: a rebuilt v5 point would get an old-format payload merged onto
  it by the note's next ordinary edit.

  ## Other writers while `on` (Task 16.4)

  A DEK rotation (`RotateUserDek`) snoozes an hour and writes nothing, and a
  bulk repath (a folder rename moving over 100 notes) snoozes an hour; a
  single-note rename still repaths. The recap cron (`IndexCapMaintenance`)
  is already a no-op.

  ## Pacing (Task 16.2)

  While `on`, each `RebuildStaleNote` job waits (`gate/0`) for two things:
  room in the maintenance token bucket (150,000 Voyage tokens a minute,
  debited by each response's `usage.total_tokens`), and a Qdrant that is
  keeping up (green, optimizer ok, at most 100 queued updates and
  `:rebuild_max_queued_points` points awaiting optimization). The
  reconcile sweep queues the pass by `rebuild_order/1`: paid users first,
  then active Free users smallest first, then inactive Free, and the users
  in `:rebuild_last_users` (the whales) last.
  """

  import Ecto.Query

  alias Engram.Accounts
  alias Engram.Backfill.TenantScan
  alias Engram.Billing
  alias Engram.Cache
  alias Engram.EmbedModels
  alias Engram.KeywordIndex
  alias Engram.Logger.Metadata
  alias Engram.Notes.Note
  alias Engram.Parsers.Markdown
  alias Engram.Rebuild.{Manifest, ManifestVault}
  alias Engram.Repo
  alias Engram.ServiceConfig
  alias Engram.UsageMeters
  alias Engram.Vector.Qdrant
  alias EngramWeb.RateLimiter

  require Logger

  # The last versions every install rebuilds automatically, without the
  # switch: the stamps prod notes carry before the v5 pass (chunker 3,
  # keyword 2). The build is at 5 / 4 (PR-17, then phrase pairs); that waits
  # for `on`.
  # `:rebuild_pinned_versions` is a test seam only (no env var, set by
  # `test_helper.exs` to the build's versions so the suite runs pins == build).
  @pinned {3, 2}

  # Spec guards: the budget is 1.15x the manifest, and a note parks once it
  # costs over 1.5x its estimate AND over 50,000 tokens.
  @budget_pct 115
  @drift_pct 150
  @drift_floor 50_000

  @meter_key {__MODULE__, :tokens}
  @paced_key {__MODULE__, :paced}

  # The maintenance token bucket (spec pass guard): Voyage tokens a minute.
  @tpm_key "voyage_maintenance_tpm"
  @tpm_tokens 150_000
  @tpm_window_ms 60_000
  # What a gated job snoozes, and the Qdrant update-queue ceiling.
  @gate_snooze 30
  @max_update_queue 100
  # "Active" Free users for the order: seen within this many days.
  @active_days 30

  @type mode :: :off | :dry_run | :on
  # A note or any map naming one and its owner (a `%Note{}` qualifies).
  @type note_ref :: %{
          required(:id) => Ecto.UUID.t(),
          required(:user_id) => Ecto.UUID.t(),
          optional(atom()) => any()
        }

  @spec mode() :: mode()
  def mode do
    case ServiceConfig.get(:index_rebuild, "off") do
      "dry_run" -> :dry_run
      "on" -> on_mode()
      _off -> :off
    end
  end

  defp on_mode do
    cond do
      halted?() -> :off
      not Qdrant.write_v5_layout?() -> v5_layout_off()
      true -> :on
    end
  end

  @v5_warned_key {__MODULE__, :v5_layout_off_warned}

  # `:off`, logging once per node: `mode/0` runs on every embed.
  defp v5_layout_off do
    unless :persistent_term.get(@v5_warned_key, false) do
      :persistent_term.put(@v5_warned_key, true)

      Logger.warning(
        "rebuild_v5_layout_off",
        Metadata.with_category(:warning, :oban)
      )
    end

    :off
  end

  @doc "`{chunker, keyword}` versions `off` and `dry_run` target: prod's pre-v5 stamps."
  # No `@spec`, as `build_versions/0`.
  def pinned_versions, do: @pinned

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
      {pin_chunker, pin_keyword} = ServiceConfig.get(:rebuild_pinned_versions, pinned_versions())
      {min(chunker, pin_chunker), min(keyword, pin_keyword)}
    end
  end

  @doc """
  True when a `chunker_version` or `keyword_version` stamp is behind `target`.
  NULL predates the stamp (or was cleared to force a rebuild), so it is
  behind; a NEWER stamp is current, so a rollback rebuilds nothing.
  """
  @spec behind?(integer() | nil, pos_integer()) :: boolean()
  def behind?(nil, _target), do: true
  def behind?(version, target), do: version < target

  @doc """
  The `{chunker, keyword}` stamp a full index pass of `note` writes: the
  target, except where the pass kept points in place (`reused?`) while that
  stamp was behind (#2199). A reused point still holds the vectors it was
  built with, so its stamp stays behind and that version's own heal runs:

    * keyword: `Engram.Workers.RefreshKeywordVectors` re-encodes every point
      in place, with no embedder call.
    * chunker, only while `on`: the v5 rebuild rewrites the note, copying
      dense vectors from the old points, on the ledger. Under `off` the
      target is stamped: a reused point's text already matches the current
      chunker by fingerprint, and staying behind would loop the version
      rebuild.
  """
  @spec pass_stamp(map(), boolean()) :: {integer() | nil, integer() | nil}
  def pass_stamp(note, reused?) do
    {chunker, keyword} = target_versions()
    old_chunker = Map.get(note, :chunker_version)
    old_keyword = Map.get(note, :keyword_version)

    {if(reused? and mode() == :on and behind?(old_chunker, chunker),
       do: old_chunker,
       else: chunker
     ), if(reused? and behind?(old_keyword, keyword), do: old_keyword, else: keyword)}
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
  (`usage.total_tokens`, from `[:engram, :voyage, :embed, :tokens]` in this
  process) to the ledger. Each response is debited the moment it is
  reported (`handle_tokens/4`), not when `fun` returns: Oban kills a job
  past its timeout and a node can die, and neither runs an `after`. Then
  the drift check: a note that cost over its limit is parked until edited.
  """
  @spec spend(Note.t(), (-> result)) :: result | {:error, :rebuild_paused}
        when result: term()
  def spend(%Note{} = note, fun) do
    # No meter, no Voyage: an unmetered rebuild would never halt.
    if attach() in [:ok, {:error, :already_exists}],
      do: metered(note, fun),
      else: {:error, :rebuild_paused}
  end

  defp metered(note, fun) do
    Process.put(@meter_key, {0, 0})

    try do
      fun.()
    after
      {total, undebited} = Process.delete(@meter_key) || {0, 0}
      _ = if undebited > 0, do: debit(undebited)
      if check_note(note, total) != :ok, do: park_drift(note, total)
    end
  end

  @doc false
  # Attached at boot, and again by `spend/2` if it went missing (`:telemetry`
  # detaches a handler that raises). Handlers run in the emitting process,
  # so this counts only the tokens of the process inside `spend/2`.
  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    :telemetry.attach(
      "engram-rebuild-token-meter",
      [:engram, :voyage, :embed, :tokens],
      &__MODULE__.handle_tokens/4,
      nil
    )
  end

  @doc false
  # The ledger debits cost, in voyage-4-large tokens (`EmbedModels.large_tokens/2`):
  # a Free note's lite tokens cost a sixth. The drift check and the token
  # bucket count raw tokens.
  def handle_tokens(_event, %{total_tokens: tokens}, meta, _config) when is_integer(tokens) do
    case Process.get(@meter_key) do
      nil ->
        _ = if Process.get(@paced_key), do: paced_debit(tokens)
        :ok

      {total, undebited} ->
        # A malformed (negative) count stays as is, so `debit/1` refuses it.
        cost = if tokens >= 0, do: EmbedModels.large_tokens(tokens, meta[:model]), else: tokens
        Process.put(@meter_key, {total + tokens, undebited + meter(tokens, cost)})
    end

    :ok
  end

  def handle_tokens(_event, _measurements, _meta, _config), do: :ok

  # The tokens left for `spend/2` to debit: 0 once this debit landed. A
  # handler that raises or exits is detached by `:telemetry` for good, and
  # every later rebuild on the node would go unmetered, so NOTHING escapes
  # here: a failed debit is logged, counted (`[:engram, :rebuild,
  # :meter_failed]`) and carried to `spend/2`'s own debit at the end, which
  # does raise.
  defp meter(tokens, cost) do
    _ = tpm_debit(tokens)
    _ = debit(cost)
    0
  rescue
    e -> meter_failed(cost, :error, Metadata.safe_reason(e))
  catch
    kind, reason -> meter_failed(cost, kind, Metadata.safe_reason(reason))
  end

  defp meter_failed(tokens, kind, reason) do
    :telemetry.execute([:engram, :rebuild, :meter_failed], %{count: 1, tokens: tokens}, %{})

    Logger.error(
      "rebuild_meter_debit_failed",
      Metadata.with_category(:error, :oban, kind: kind, reason: reason, total_count: tokens)
    )

    # A malformed (negative) count carries nothing.
    max(tokens, 0)
  end

  @doc """
  `:ok`, or `{:snooze, 30}` while the pass must wait: the maintenance token
  bucket is spent for this minute, or Qdrant is behind (not green, optimizer
  not ok, more than 100 queued updates, or more than
  `:rebuild_max_queued_points` (default 50,000) points awaiting
  optimization). Unreadable health counts as behind. Only while `on`: off
  and `dry_run` never gate, and never call Qdrant here.
  """
  @spec gate() :: :ok | {:snooze, 30}
  def gate, do: if(mode() == :on, do: pace(), else: :ok)

  @doc """
  Runs `fun` with its Voyage tokens debited from the maintenance token
  bucket, as a metered rebuild's are, but not from the ledger: a plan
  upgrade's re-embed outside `on` (`Engram.EmbedModels`), so a whale's
  upgrade cannot spike Voyage.
  """
  @spec paced((-> result)) :: result when result: term()
  def paced(fun) do
    _ = attach()
    prev = Process.put(@paced_key, true)

    try do
      fun.()
    after
      if prev, do: Process.put(@paced_key, prev), else: Process.delete(@paced_key)
    end
  end

  # Never raises: a raising handler is detached for good.
  defp paced_debit(tokens) do
    _ = tpm_debit(tokens)
    :ok
  rescue
    e -> meter_failed(tokens, :error, Metadata.safe_reason(e))
  catch
    kind, reason -> meter_failed(tokens, kind, Metadata.safe_reason(reason))
  end

  @doc """
  `gate/0`'s checks in any mode: a plan-upgrade re-embed
  (`Engram.EmbedModels`) is paced like the pass even when it is off.
  """
  @spec pace() :: :ok | {:snooze, 30}
  def pace do
    cond do
      not tpm_room?() -> gated(:tokens)
      not qdrant_ready?() -> gated(:qdrant)
      true -> :ok
    end
  end

  # A check costs the bucket 1 token (Hammer has no read without a hit).
  defp tpm_room?,
    do: match?({:allow, _}, RateLimiter.hit(@tpm_key, @tpm_window_ms, @tpm_tokens, :voyage_embed))

  defp tpm_debit(0), do: :ok

  defp tpm_debit(tokens),
    do: RateLimiter.hit(@tpm_key, @tpm_window_ms, @tpm_tokens, :voyage_embed, tokens)

  defp qdrant_ready? do
    col = Qdrant.collection_name()

    case Qdrant.collection_info(col, :search) do
      {:ok, %{"status" => "green", "optimizer_status" => "ok"} = info} ->
        (get_in(info, ["update_queue", "length"]) || 0) <= @max_update_queue and
          optimizer_caught_up?(col)

      _ ->
        false
    end
  end

  defp optimizer_caught_up?(col) do
    case Qdrant.optimizations(col) do
      {:ok, %{"summary" => %{"queued_points" => queued}}} when is_integer(queued) ->
        queued <= ServiceConfig.get(:rebuild_max_queued_points, 50_000)

      # Before Qdrant 1.17 there is no endpoint: status and update queue gate.
      {:error, :unsupported} ->
        true

      _ ->
        false
    end
  end

  defp gated(reason) do
    :telemetry.execute([:engram, :rebuild, :gated], %{count: 1}, %{reason: reason})
    {:snooze, @gate_snooze}
  end

  @doc """
  The pass order of `user_ids`, each with the Oban priority its rebuild jobs
  get: 6 paid, 7 Free active within 30 days, 8 other Free, 9 the users in
  `:rebuild_last_users` (the whales, last whatever their plan). Within a
  class the smaller account (`usage_meters.notes_count`) goes first.
  """
  @spec rebuild_order([Ecto.UUID.t()]) :: [{Ecto.UUID.t(), 6..9}]
  def rebuild_order(user_ids) do
    user_ids = Enum.uniq(user_ids)
    whales = MapSet.new(ServiceConfig.get(:rebuild_last_users, []))
    since = DateTime.add(DateTime.utc_now(), -@active_days * 86_400, :second)

    # `usage_meters` is not a tenant table (`UsageMeters.last_active_at/1`).
    meters =
      from(m in UsageMeters.Meter,
        where: m.user_id in ^user_ids,
        select: {m.user_id, {m.last_active_at, m.notes_count}}
      )
      |> Repo.all(skip_tenant_check: true)
      |> Map.new()

    user_ids
    |> Enum.map(fn id ->
      {active_at, notes} = Map.get(meters, id, {nil, 0})
      {id, priority(id, whales, active_at, since), notes || 0}
    end)
    |> Enum.sort_by(fn {_id, priority, notes} -> {priority, notes} end)
    |> Enum.map(fn {id, priority, _notes} -> {id, priority} end)
  end

  defp priority(id, whales, active_at, since) do
    cond do
      MapSet.member?(whales, id) -> 9
      paid?(id) -> 6
      active_at != nil and DateTime.compare(active_at, since) != :lt -> 7
      true -> 8
    end
  end

  defp paid?(user_id) do
    case Accounts.get_user_with_subscription(user_id) do
      nil -> false
      user -> Billing.paid?(user)
    end
  end

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
    park_until_edited(note)

    :telemetry.execute([:engram, :rebuild, :drift_parked], %{count: 1, tokens: tokens}, %{})

    Logger.warning(
      "rebuild_drift_parked",
      Metadata.with_category(:warning, :oban, note_id: note.id, total_count: tokens)
    )
  end

  @doc """
  Parks a note whose rebuild was about to pay Voyage a second time for the
  same content (`notes.rebuild_paid_at` set, chunker v5 Task 16.3), until
  edited. Returns `{:error, :rebuild_double_pay}`.
  """
  @spec park_double_pay(note_ref()) :: {:error, :rebuild_double_pay}
  def park_double_pay(note) do
    park_until_edited(note)
    :telemetry.execute([:engram, :rebuild, :double_pay_parked], %{count: 1}, %{})

    Logger.warning(
      "rebuild_double_pay_parked",
      Metadata.with_category(:warning, :oban, note_id: note.id)
    )

    {:error, :rebuild_double_pay}
  end

  defp park_until_edited(note) do
    {:ok, _} =
      Repo.with_tenant(note.user_id, fn ->
        Repo.update_all(from(n in Note, where: n.kind == "note" and n.id == ^note.id),
          set: [embed_retry_after: Engram.Workers.EmbedNote.parked_until_edited()]
        )
      end)

    :ok
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
               [:dl_sum, :dl_count, :planned_at, :model]},
          conflict_target: :note_id
        )
      end)

    :ok
  end

  @doc """
  Closes a dry run: pins each vault's `avgdl` from the manifest and sets the
  budget to 1.15x the manifest's estimated tokens. That is a ceiling, not a
  forecast: the per-user vector cache pays a text shared across notes once,
  and the manifest counts it per note (`Indexing.rebuild_estimate/2`), so a
  corpus with repeated text spends well under it. Only while the mode is
  still `dry_run`. The budget is set only when none exists (an operator's
  budget wins, and a halt is never cleared here), and once a budget exists
  the pins are never replaced, only added for vaults that had none, so a
  late seal cannot move a running pass's avgdl. Per tenant, as
  `ReconcileEmbeddings` scans.
  """
  @spec seal() :: {:ok, non_neg_integer()} | {:error, :not_dry_run | :v5_layout_off}
  def seal do
    cond do
      mode() != :dry_run ->
        {:error, :not_dry_run}

      not Qdrant.write_v5_layout?() ->
        _ = v5_layout_off()
        {:error, :v5_layout_off}

      true ->
        do_seal()
    end
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

        # Priced per note at its plan's model (`EmbedModels.large_tokens/2`).
        from(m in Manifest, group_by: m.model, select: {m.model, coalesce(sum(m.est_tokens), 0)})
        |> repo.all()
        |> Enum.map(fn {model, tokens} -> EmbedModels.large_tokens(to_integer(tokens), model) end)
        |> Enum.sum()
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
