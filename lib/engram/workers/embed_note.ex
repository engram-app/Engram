defmodule Engram.Workers.EmbedNote do
  @moduledoc """
  Oban worker: embeds a note and upserts to Qdrant.

  Debounce: 30-second trailing settle (`:embed_settle_seconds`) with a 300s
  max-wait ceiling, so rapid edits trigger only one Voyage API call. See
  `new_debounced/3`.

  Does not write `note_links`; `ExtractNoteLinks` owns those.

  Dedup: unique per note_id across all `:incomplete` states (which includes
  `executing` and `retryable`, not just available/scheduled), 60-second window.

  Idempotency: skips embedding when embed_hash already matches content_hash
  (content hasn't changed since last successful embed). On success, sets
  embed_hash = content_hash using an optimistic lock — if content changed
  mid-embed, the update is a no-op and the next job picks up the new version.

  That skip is also gated on `chunker_version` (#1620): content being unchanged
  is not enough if the chunks were built by an older chunker, so a note stamped
  below the target chunker (`Engram.Rebuild.target_versions/0`), or not at
  all, is rebuilt rather than skipped. A newer stamp is current, so a
  rollback rebuilds nothing. Version-stale notes are re-embedded by the
  `IndexVersions` data migration (`Engram.DataMigrations`).

  A chunker bump alone does not re-normalize BM25 against a drifted `avgdl`:
  that involves no chunker change, so it never makes a note look stale here,
  and chunk reuse would keep the old weights even if it did. A genuine rebuild
  clears both the reuse markers and these hashes first
  (`Indexing.flag_notes_for_rebuild/2`, #1477).
  """

  use Oban.Worker,
    queue: :embed,
    max_attempts: 5,
    unique: [
      period: 60,
      keys: [:note_id],
      states: :incomplete
    ]

  import Ecto.Query

  alias Engram.Accounts
  alias Engram.Accounts.User
  alias Engram.Billing
  alias Engram.Crypto
  alias Engram.Crypto.RotationGate
  alias Engram.EmbedModels
  alias Engram.Indexing
  alias Engram.Logger.DecryptFailure
  alias Engram.Logger.Metadata
  alias Engram.Notes.Note
  alias Engram.Rebuild
  alias Engram.Repo
  alias Engram.ServiceConfig
  alias Engram.UsageMeters
  alias Engram.Vaults.Vault
  alias Engram.Vector.Qdrant
  alias Engram.Workers.BackgroundPriority
  alias Engram.Workers.EmbedNote.CrashGuard

  require Logger

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  # An unavailable upstream (Qdrant restart, Voyage 5xx) waits 60s, 120s, 240s,
  # 480s (capped at 600s, +10% jitter): ~15 min before the terminal attempt.
  # Oban's default (15s + 2^attempt) spent all 5 attempts in ~90s, so a 3 min
  # Qdrant resize on 2026-10-19 poisoned 11 notes. A sustained outage still
  # reaches the terminal attempt and the short transient poison cooldown.
  # Paid vectors survive the wait: Indexing retains them across the commit.
  @impl Oban.Worker
  def backoff(
        %Oban.Job{
          attempt: attempt,
          unsaved_error: %{reason: %Oban.PerformError{reason: {:error, reason}}}
        } = job
      ) do
    if transient_embed_error?(reason) do
      (60 * Integer.pow(2, attempt - 1))
      |> min(600)
      |> Oban.Backoff.jitter(mode: :inc)
    else
      Oban.Worker.backoff(job)
    end
  end

  def backoff(job), do: Oban.Worker.backoff(job)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    :ok = BackgroundPriority.demote()
    # T3.2 — `old_path_hmac` is a base64-encoded HMAC, never plaintext path.
    old_path_hmac_b64 = args["old_path_hmac"]

    case load(args, old_path_hmac_b64) do
      {:run, note, user, vault, opts} ->
        opts = if cap = args["budget_cap"], do: [{:budget_cap, cap} | opts], else: opts

        run_and_stamp(
          note,
          user,
          vault,
          old_path_hmac_b64,
          job,
          opts ++ embed_purpose(job) ++ [embed_trigger: embed_trigger(job)]
        )

      other ->
        other
    end
  end

  # A RebuildStaleNote job is our maintenance: its Voyage calls never retry
  # once they may have been billed (`Voyage.request_defaults(:maintenance)`, H6).
  defp embed_purpose(%Oban.Job{worker: "Engram.Workers.RebuildStaleNote"}),
    do: [embed_purpose: :maintenance]

  defp embed_purpose(_job), do: []

  # Why this pass runs, for the Voyage token metric's closed `trigger` enum
  # (`Engram.Embedders.UsageLabels`). A RebuildStaleNote is a version rebuild
  # or, with `upgrade: true`, a plan-model upgrade; a re-attempt is a retry;
  # backfill priority is the reconcile sweep; the rest is a user edit.
  @doc false
  @spec embed_trigger(Oban.Job.t()) :: :edit | :rebuild | :upgrade | :retry | :reconcile
  def embed_trigger(%Oban.Job{worker: "Engram.Workers.RebuildStaleNote", args: args}),
    do: if(args["upgrade"], do: :upgrade, else: :rebuild)

  def embed_trigger(%Oban.Job{attempt: attempt}) when attempt > 1, do: :retry

  def embed_trigger(%Oban.Job{priority: priority}),
    do: if(priority == backfill_priority(), do: :reconcile, else: :edit)

  # Every read the job needs before it embeds, in ONE tenant transaction: the
  # note, the user and the vault used to open one each (3 round trips
  # apiece). Reads only, so nothing here holds a lock, and the
  # Voyage call is far below, outside any transaction. The inner `with_tenant`
  # calls are re-entrant for the same tenant and cost nothing.
  #
  # A legacy job (no `user_id` in args) has no tenant to open it with; it takes
  # the unscoped path, which discards under an RLS-enforcing role anyway.
  defp load(%{"user_id" => user_id} = args, old_path_hmac_b64) when is_binary(user_id),
    do: Repo.with_tenant!(user_id, fn -> route(args, old_path_hmac_b64) end)

  defp load(args, old_path_hmac_b64), do: route(args, old_path_hmac_b64)

  defp route(args, old_path_hmac_b64) do
    case Engram.Notes.fetch_note_for_worker_job(args) do
      {:discard, _reason} = discard ->
        discard

      {:ok, %Note{content_hash: hash, embed_hash: hash} = note}
      when hash != nil and is_nil(old_path_hmac_b64) ->
        cond do
          # The index points budget (`ReconcileEmbeddings.budget_sweep/1`)
          # stamped this note "floor"/"floor_paid": rebuild it as one keyword
          # point. Never metered (a floor plan reserves nothing).
          args["index_budget"] == "demote" and Indexing.floor_tier(note) != nil ->
            load_for_run(note, maintenance: true)

          # The budget has room again: a full pass. A "floor_paid" note had
          # dense vectors we deleted, so its are rebuilt unmetered; a
          # "floor" one never had them and is metered as a first embed. The
          # pass refuses to commit if the tier moved meanwhile.
          args["index_budget"] == "promote" and Indexing.floor_tier(note) != nil ->
            load_for_run(note, index_tier: nil, maintenance: note.index_tier == "floor_paid")

          # Indexed by an older chunker (#1620; NULL predates the stamp) or
          # another embed model. Content unchanged, so this is OUR maintenance,
          # not the user's usage: a note that has dense vectors gets them
          # rebuilt unmetered, even over a spent cap, and keeps them. A
          # sparse-only note stays on the normal budget, so a version bump
          # never grants dense vectors the cap refused. `run_and_stamp`
          # re-stamps both versions, so this matches at most once per bump.
          #
          # While the v5 rebuild is `on`, its tokens go through the ledger
          # (`rebuild: true`, see `index/5`).
          version_stale?(note) ->
            load_for_run(
              note,
              Indexing.version_rebuild_opts(note) ++ [rebuild: Rebuild.mode() == :on]
            )

          # Holds more chunks than its tier's per-note cap (ReconcileEmbeddings
          # found it): re-merge it, unmetered. It already has dense vectors, so
          # this is our maintenance, never a second charge.
          args["recap"] == true and note.dense_indexed_hash == hash ->
            load_for_run(note, maintenance: true, keep_dense: true)

          # The key alias table moved and this note's frontmatter now reads
          # differently (`Engram.Workers.HealKeyAliases`): a pass that reuses
          # every unchanged vector (0 Voyage) and refreshes the payload; only a
          # changed chunk-0 lead line (a type/description alias) re-embeds.
          args["key_aliases"] == true ->
            load_for_run(note, Indexing.version_rebuild_opts(note))

          # Current content, chunker and model, with dense vectors: skip.
          note.dense_indexed_hash == hash ->
            :ok

          # Floor-indexed at its current content: a floor note has no dense
          # leg to backfill. Promoting it back to a full index is the index
          # budget's call (an `index_budget: "promote"` job), not this job's.
          Indexing.floor_tier(note) ->
            :ok

          true ->
            dense_backfill(note)
        end

      # The current content already has dense vectors, so this pass is OUR
      # rebuild, not new content: OrphanSweep's `flag_notes_for_rebuild/2`
      # (clears `embed_hash` and the reuse markers, keeps this hash) and the
      # rename fallback after a failed repath (`old_path_hmac`). Unmetered, like
      # a version rebuild: neither may spend a Free user's bucket.
      {:ok, %Note{content_hash: hash, dense_indexed_hash: hash} = note} when hash != nil ->
        load_for_run(note, maintenance: true)

      {:ok, note} ->
        load_for_run(note, [])
    end
  end

  defp dense_backfill(note) do
    # Content is indexed but has no dense vectors: the dense backfill for
    # a note indexed sparse-only (Free before semantic search was every
    # tier's, or a pass that ran with the embed budget spent). If the
    # budget is already spent, the sparse index is in place, so park the
    # note instead of rebuilding it — otherwise ReconcileEmbeddings
    # re-selects it every tick forever. Otherwise the pass itself reserves
    # exactly what it needs (see `budget_opts/3`).
    # Loaded once here and handed to run_and_stamp — it needs the same row
    # for the rotation gate, so re-resolving would cost a second read on
    # exactly the path that already paid for one. See #1502.
    case Accounts.get_user_with_subscription(note.user_id) do
      nil ->
        {:discard, :user_deleted}

      user ->
        # A note with no chunk rows has NO index to keep, so parking it
        # would leave it unsearchable: the shape the removed
        # search-coverage cap left behind. Run it; the pass indexes it
        # sparse-only and parks it itself. The chunk check is only paid
        # on the budget-spent path.
        cond do
          not budget_blocks?(user, note) ->
            load_for_run(note, [], user)

          # Spent budget is already known: index keyword-only without
          # asking for a reservation, so a former over-cap vault's
          # backfill does not fire one abuse event per note.
          not has_chunks?(note) ->
            load_for_run(note, [budget_spent: true], user)

          true ->
            park_over_budget(note, user)
        end
    end
  end

  # `_with_subscription`: the budget gate calls `Billing.limit_enforced?/2`
  # and then `check_limit/3`, and each resolves the tier via
  # `get_subscription/1` — which queries unless the association is already
  # loaded. On a bare `get_user/1` struct that is two `subscriptions`
  # round trips per job. The join makes them zero at no extra query, since
  # this fetch has to happen anyway. See #1502.
  #
  # Missing vault means the note is orphaned — nothing to index, discard.
  # Tenant-scoped: `vaults` carries FORCE ROW LEVEL SECURITY, so unscoped
  # this returns nil for a vault that plainly exists and EVERY embed
  # discards as "orphaned".
  defp load_for_run(note, opts, user \\ nil) do
    case user || Accounts.get_user_with_subscription(note.user_id) do
      nil ->
        {:discard, :user_deleted}

      %User{} = user ->
        case Repo.with_tenant!(note.user_id, fn -> Repo.get(Vault, note.vault_id) end) do
          nil ->
            {:discard, "vault #{note.vault_id} not found for note #{note.id}"}

          %Vault{} = vault ->
            {:run, note, user, vault, with_queue_position(note, user, opts)}
        end
    end
  end

  # T3.7 — gate writes during DEK rotation. The worker may have been enqueued
  # before the lock was acquired, so this must read live state.
  #
  # ONE read, not two. This used to call `RotationGate.check/1` (which selects
  # `{id, dek_rotation_locked_at}`) and then `get_user!/1` for the full row —
  # two `users` queries per job for the same row, which is the 2.1/job measured
  # in prod 2026-08-28. The full row already carries `dek_rotation_locked_at`,
  # so `check_user/1` answers the same question from the struct we need anyway.
  #
  # This is also strictly MORE consistent than the two-query form. With separate
  # reads, a rotation starting between them let a job pass a pre-rotation check
  # and then operate on a post-rotation user. Gating on the same struct that
  # gets used closes that window.
  #
  # The moduledoc's advice to prefer `check/1` is about structs loaded LONG
  # before use (an open socket, a job enqueued seconds before the lock). It does
  # not apply to one fetched at the top of this job: the read is exactly as
  # fresh as `check/1` was, and it is the read whose result is actually used.
  #
  # `user` is resolved once in `load/2` and passed down from here — the budget
  # gate, the decrypt in run_embed and both halves of Indexing all take it.
  # Nothing below may re-resolve it. See #1502.
  defp run_and_stamp(note, user, vault, old_path_hmac_b64, job, opts) do
    case RotationGate.check_user(user) do
      {:error, :rotation_in_progress} ->
        :telemetry.execute(
          [:engram, :crypto, :rotate, :dek, :gate_blocked],
          %{count: 1},
          %{gate_path: :worker, op: :embed_note}
        )

        {:snooze, 60}

      :ok ->
        # An over-budget pass still runs, sparse-only: cancelling it (the
        # old behaviour) left the note with no BM25 index either, so it
        # vanished from keyword search too. The meter is charged inside
        # the pass, by the reservation (see `reserve_embed_tokens/2`).
        case CrashGuard.check(note, job) |> preflight() do
          # Qdrant is near strict mode's write refusal: wait BEFORE reserving
          # tokens or paying Voyage for vectors it may refuse to store.
          :over_pressure ->
            Qdrant.backpressure_snooze(:preflight)

          :run ->
            case guarded_embed(note, user, vault, old_path_hmac_b64, opts) do
              :ok ->
                :ok

              other ->
                _ = maybe_mark_poison(note, other, job)
                other
            end

          other ->
            other
        end
    end
  end

  # Fails open: an unknown reading (self-host, Qdrant unreachable, no memory
  # limit configured) is never over pressure.
  defp preflight(:run) do
    if ServiceConfig.get(:qdrant_backpressure_preflight, true) and
         Qdrant.over_pressure?(Qdrant.pressure()),
       do: :over_pressure,
       else: :run
  end

  defp preflight(other), do: other

  # The dead-man stamp brackets the embed: written before, cleared however the
  # attempt returns, raise and exit included. Only a killed node leaves it.
  # A success clears it inside the index write's transaction
  # (`stamp_embed_hash/3`), so only the other outcomes clear it here.
  defp guarded_embed(note, user, vault, old_path_hmac_b64, opts) do
    :ok = CrashGuard.stamp(note)

    try do
      result = run_embed(note, user, vault, old_path_hmac_b64, opts)
      if result != :ok, do: :ok = CrashGuard.clear(note, result)
      result
    rescue
      e ->
        _ = CrashGuard.clear(note, :error)
        reraise e, __STACKTRACE__
    catch
      :exit, reason ->
        _ = CrashGuard.clear(note, :error)
        exit(reason)
    end
  end

  # Voyage/Qdrant non-2xx surface as {status, body}; pull the bounded HTTP
  # status (401 vs 429 vs 500 vs 503 is the on-call triage signal). nil for a
  # transport error (timeout/closed), which error_kind names by struct instead.
  defp embed_error_status({status, _body}) when is_integer(status), do: status
  defp embed_error_status(_), do: nil

  # Free's refilling embed-token bucket (`embed_token_bucket`, which replaced
  # the 20M lifetime cap). Resolver returns nil for Starter/Pro (unmetered), so
  # this binds on Free. Per-user overrides via Billing.UserLimitOverride.
  #
  # Reserved per pass, for exactly the tokens the pass would send AFTER chunk
  # reuse — a one-section edit asks for one section, not the whole note — and
  # atomically, so concurrent jobs cannot all pass on one reading of the meter.
  # A refusal never blocks INDEXING: the pass runs sparse-only, so the note
  # stays keyword-searchable. The reservation IS the charge (#1618: what Voyage
  # is sent, nothing more); a failed embed gives it back.
  #
  # Queued behind the parked backlog: while another note of this user waits on
  # the bucket, a new pass spends nothing (`queue_blocked?/1`) and its new
  # chunks join the queue keyword-only; ReconcileEmbeddings decides who wakes.
  # A woken head note spends at most its `:budget_cap`. A refused or
  # partly-fitting pass keeps every dense vector the note already has
  # (`Indexing` re-plans only the new chunks).
  defp budget_opts(user, opts, false) do
    case Billing.effective_limit(user, :embed_token_bucket) do
      cap when is_integer(cap) and cap >= 0 ->
        blocked? = Keyword.get(opts, :queued_behind, false)
        limit = Keyword.get(opts, :budget_cap)

        [
          reserve_tokens: fn tokens ->
            not blocked? and (is_nil(limit) or tokens <= limit) and
              match?({:ok, _}, UsageMeters.bucket_take(user.id, tokens, cap))
          end,
          budget_available: fn ->
            cond do
              blocked? -> 0
              limit -> min(limit, UsageMeters.bucket_available(user.id, cap))
              true -> UsageMeters.bucket_available(user.id, cap)
            end
          end,
          release_tokens: &UsageMeters.release_embed_tokens(user.id, &1)
        ]

      # nil / :unlimited / a negative sentinel: unmetered, still recorded.
      cap when is_nil(cap) or cap == :unlimited or is_integer(cap) ->
        [
          reserve_tokens: fn tokens ->
            _ = UsageMeters.add_embed_tokens(user.id, tokens)
            true
          end,
          release_tokens: &UsageMeters.release_embed_tokens(user.id, &1)
        ]

      # A malformed override fails CLOSED, as `check_limit/3` always did.
      _malformed ->
        [reserve_tokens: fn _ -> false end, release_tokens: fn _ -> :ok end]
    end
  end

  # A version rebuild (chunker or embed model bump, content unchanged) is our
  # maintenance: never refused, never charged to the user. Its spend is ours,
  # reported as `[:engram, :embed, :maintenance]`: + at the reservation, - on
  # release.
  defp budget_opts(_user, _opts, true) do
    [
      reserve_tokens: fn tokens ->
        :telemetry.execute([:engram, :embed, :maintenance], %{tokens: tokens}, %{})
        true
      end,
      # A failed or 429-snoozed embed gives its reservation back, so the
      # sum counts what was actually sent.
      release_tokens: fn tokens ->
        :telemetry.execute([:engram, :embed, :maintenance], %{tokens: -tokens}, %{})
      end
    ]
  end

  @doc """
  True when an indexed note is behind this build: an older chunker, or dense
  vectors from a model the note may not keep (`Engram.EmbedModels`: per
  plan, a downgrade keeps its vectors). The single definition both
  `perform/1` and `ReconcileEmbeddings` route on. Model tracking is off when
  the build cannot name its model (nil). `paid?` is the owner's
  `Billing.paid?/1`; nil looks it up when the model term needs it.
  """
  def version_stale?(%Note{} = note, paid? \\ nil) do
    {chunker, _keyword} = Rebuild.target_versions()
    chunker_stale?(note.chunker_version, chunker) or model_stale?(note, paid?)
  end

  @doc """
  Stale only by its model (a plan upgrade, or a pre-tracking stamp): the
  reconcile sweep queues these as paced, lowest-priority rebuilds.
  """
  def model_only_stale?(%Note{} = note, paid? \\ nil) do
    {chunker, _keyword} = Rebuild.target_versions()
    not chunker_stale?(note.chunker_version, chunker) and model_stale?(note, paid?)
  end

  # `Rebuild.behind?/2`: nil is stale, a newer chunker is current. The
  # target is `Rebuild.target_versions/0`'s: the pin while the v5 rebuild is
  # not `on`, so a stamp bump alone rebuilds nothing.
  defp chunker_stale?(version, target), do: Rebuild.behind?(version, target)

  defp model_stale?(note, paid?) do
    note.dense_indexed_hash == note.content_hash and
      case keepable_models(note, paid?) do
        nil -> false
        models -> note.embed_model not in models
      end
  end

  defp keepable_models(note, paid?) do
    cond do
      EmbedModels.per_plan?() -> EmbedModels.acceptable(plan_class(note, paid?))
      model = Indexing.embed_model() -> [model]
      true -> nil
    end
  end

  defp plan_class(_note, true), do: :paid
  defp plan_class(_note, false), do: :free

  defp plan_class(note, nil) do
    case Accounts.get_user_with_subscription(note.user_id) do
      nil -> :free
      user -> plan_class(note, Billing.paid?(user))
    end
  end

  # Cheap pre-check for the dense backfill of an already-indexed note: when
  # the queue is ahead of it or the bucket is empty, park it (keeping its
  # place) without a rebuild that could only be refused. A note woken by
  # ReconcileEmbeddings fits by construction.
  defp budget_blocks?(user, note) do
    case Billing.effective_limit(user, :embed_token_bucket) do
      cap when is_integer(cap) and cap >= 0 ->
        queue_blocked?(note) or UsageMeters.bucket_available(user.id, cap) == 0

      cap when is_nil(cap) or cap == :unlimited or is_integer(cap) ->
        false

      _malformed ->
        true
    end
  end

  # Read here, inside `load/2`'s tenant transaction (the inner `with_tenant!`
  # is re-entrant), so the budget check costs no transaction of its own.
  # Only a metered pass can wait: maintenance, a known-spent backfill and a
  # user with no bucket (paid, a -1 override) skip the query.
  defp with_queue_position(note, user, opts) do
    if opts[:maintenance] || opts[:budget_spent] || not free_bucket?(user),
      do: opts,
      else: Keyword.put(opts, :queued_behind, queue_blocked?(note))
  end

  defp free_bucket?(user) do
    case Billing.effective_limit(user, :embed_token_bucket) do
      cap when is_integer(cap) and cap >= 0 -> true
      _ -> false
    end
  end

  @doc """
  True when another of the user's notes waits on the embed bucket ahead of
  `note`: any waiting note for one that is not queued, an older one for a
  waiting note (its `embed_budget_parked_at` is its place). A note
  ReconcileEmbeddings woke (`embed_budget_parked` cleared, place kept) is never
  blocked: the wake is first fit, so it may run while an older, bigger note
  still waits. Woken notes do not block others either, so a note that keeps
  failing after waking cannot stall the queue.
  """
  def queue_blocked?(%Note{embed_budget_parked: nil, embed_budget_parked_at: %DateTime{}}),
    do: false

  def queue_blocked?(%Note{} = note) do
    Repo.with_tenant!(note.user_id, fn ->
      base =
        from(n in Note,
          where:
            n.kind == "note" and is_nil(n.deleted_at) and n.id != ^note.id and
              n.embed_budget_parked == true
        )

      query =
        case note.embed_budget_parked_at do
          nil ->
            base

          at ->
            where(
              base,
              [n],
              not is_nil(n.embed_budget_parked_at) and n.embed_budget_parked_at < ^at
            )
        end

      Repo.exists?(query)
    end)
  end

  # The usage endpoint shows the bucket, but nothing pushes it at the user,
  # so product analytics hears it here or not at all. Once a day per user, for
  # the log and telemetry too: a Free user writing behind a backlog parks every
  # note, and each wake that re-parks one would fire again.
  defp budget_exhausted(%{id: user_id} = user) do
    case EngramWeb.RateLimiter.hit("embed_budget_exhausted:#{user_id}", :timer.hours(24), 1) do
      {:allow, _} -> report_budget_exhausted(user)
      _deny -> :ok
    end

    false
  end

  defp report_budget_exhausted(%{id: user_id} = user) do
    Engram.Analytics.track_limit_hit(
      user,
      :embed_token_bucket,
      %{silent: true},
      :timer.hours(24)
    )

    :telemetry.execute(
      [:engram, :abuse, :embed_budget_exhausted],
      %{count: 1, lifetime_tokens: UsageMeters.lifetime_embed_tokens(user_id)},
      %{user_id: user_id}
    )

    Logger.warning(
      "EmbedNote indexing sparse-only, embed-token bucket empty",
      Metadata.with_category(:warning, :search,
        user_id: user_id,
        reason_label: :embed_budget_exhausted
      )
    )
  end

  # A budget-parked note waits with no clock: `embed_retry_after` is the
  # never-reached `@parked_until_edited`, so no sweep re-runs it. It leaves the
  # queue when ReconcileEmbeddings wakes it (its `embed_budget_need` fits the
  # bucket, oldest `embed_budget_parked_at` first), when it is edited, or when
  # the user upgrades (`embed_budget_parked` lets the sweep tell this park from
  # a poison cooldown).
  defp budget_park_set(note, need, next) do
    [
      embed_retry_after: parked_until_edited(),
      embed_budget_parked: true,
      embed_budget_need: need,
      embed_budget_next: next,
      embed_budget_parked_at: note.embed_budget_parked_at || DateTime.utc_now()
    ]
  end

  # Set by run_embed's `in_commit`: whether the stamp parked the note on the
  # bucket. Read and deleted in the same process once the pass returns.
  @budget_parked_key {__MODULE__, :budget_parked}

  @queue_clear [
    embed_budget_parked: nil,
    embed_budget_need: nil,
    embed_budget_next: nil,
    embed_budget_parked_at: nil
  ]

  # Tenant-scoped: `chunks` is under FORCE RLS, and a tenant-less read sees
  # zero rows, which would run (not park) every budget-spent note.
  defp has_chunks?(%Note{} = note) do
    Repo.with_tenant!(note.user_id, fn ->
      Repo.exists?(from(c in Engram.Notes.Chunk, where: c.note_id == ^note.id))
    end)
  end

  # Tenant-scoped for the same filtered-UPDATE reason as `maybe_mark_poison/3`.
  # A note parked before the queue existed has no need recorded: the whole
  # note is the upper bound.
  defp park_over_budget(%Note{} = note, user) do
    need = note.embed_budget_need || UsageMeters.estimate_tokens(note.content_ciphertext || "")

    {:ok, _} =
      Repo.with_tenant(note.user_id, fn ->
        Repo.update_all(from(n in Note, where: n.id == ^note.id),
          set: budget_park_set(note, need, note.embed_budget_next)
        )
      end)

    newly_parked(note, user)
  end

  # Logged once, when a note joins the queue, not on every pass that finds it
  # still waiting.
  defp newly_parked(%Note{embed_budget_parked: true}, _user), do: :ok

  defp newly_parked(_note, user) do
    _ = budget_exhausted(user)
    :ok
  end

  # Snooze duration after Voyage 429. Env-driven via `EMBED_429_SNOOZE_SECONDS`
  # (wired in runtime.exs) so we can tune as Voyage RPM allotment grows. 60s is
  # the right default for free-tier (3 RPM) and a safe ceiling for paid tier.
  defp snooze_seconds_on_429 do
    Application.get_env(:engram, :embed_429_snooze_seconds, 60)
  end

  # Cooldown parked on a note that has exhausted its embed attempts. Env-driven
  # via `EMBED_POISON_COOLDOWN_SECONDS` (wired in runtime.exs). Default 6h: a
  # genuinely-broken note re-bills Voyage ~4×/day instead of ~96×/day, while a
  # transient provider outage self-heals within hours (vs a hard give-up that
  # would strand the whole vault until manual reset).
  # Classify the failure so a transient/infra outage isn't parked for the full
  # persistent-failure cooldown. On 2026-07-19 a Qdrant outage made embeds fail
  # with Req.TransportError; the flat 6h poison then stranded every affected
  # note for 6h even after Qdrant recovered. "Upstream unreachable / temporarily
  # unavailable" recovers on its own, so park briefly and let ReconcileEmbeddings
  # re-embed on its next pass; keep the long cooldown only for failures that
  # won't fix themselves on retry (4xx / unembeddable content / unknown).
  # NOTE: the transient default (300s) is a floor, not the real recovery time —
  # ReconcileEmbeddings sweeps every 5 min, so a parked note re-embeds on the
  # first sweep after the cooldown lapses. Dropping it below ~300s buys
  # nothing; raise it only to back off harder on a sustained outage.
  defp poison_cooldown_seconds(reason) do
    if transient_embed_error?(reason) do
      Application.get_env(:engram, :embed_transient_cooldown_seconds, 300)
    else
      Application.get_env(:engram, :embed_poison_cooldown_seconds, 21_600)
    end
  end

  # Transient = the embed/index upstream (Ollama, Voyage, Qdrant) was unreachable
  # or temporarily unavailable. A transport error is "not reachable"; any 5xx is
  # "reachable but unhappy" — status >= 500 (not a fixed 500/502/503/504 list) so
  # CDN-injected 52x (Cloudflare), 507, 529 in front of a provider also count.
  # (429 is already handled earlier as a snooze and never reaches here.)
  # Everything else — 4xx, decrypt failures, unknown — is treated as persistent.
  defp transient_embed_error?(%Req.TransportError{}), do: true
  defp transient_embed_error?({status, _body}) when is_integer(status) and status >= 500, do: true
  defp transient_embed_error?(_), do: false

  # Final-attempt failure: park the note for a cooldown so ReconcileEmbeddings
  # stops re-enqueuing (and re-billing) it every 5 minutes. Only fires on the
  # terminal Oban attempt and only for {:error, _} — snooze/cancel/discard are
  # not embed failures. Like stamp_embed_hash, an optimistic content_hash guard
  # avoids parking content that was edited mid-flight — but a nil content_hash
  # must still park (WHERE content_hash = NULL never matches, which would leave
  # the exact loop this guards against running), so fall back to an id-only match.
  defp maybe_mark_poison(note, {:error, reason}, %Oban.Job{attempt: attempt, max_attempts: max})
       when attempt >= max,
       do: park_poisoned(note, reason)

  defp maybe_mark_poison(_note, _result, _job), do: :ok

  defp park_poisoned(note, reason) do
    cooldown = poison_cooldown_seconds(reason)
    retry_after = DateTime.add(DateTime.utc_now(), cooldown, :second)

    park_query =
      if is_nil(note.content_hash) do
        from(n in Note, where: n.id == ^note.id)
      else
        from(n in Note, where: n.id == ^note.id and n.content_hash == ^note.content_hash)
      end

    error_kind = Engram.Telemetry.error_kind(reason)
    status = embed_error_status(reason)

    # Logged BEFORE the park is attempted, deliberately. This whole function
    # runs only on the terminal attempt — i.e. during an outage — and the park
    # below now opens a transaction (BEGIN / SET LOCAL / COMMIT). If that
    # raises on an exhausted pool, the ORIGINAL upstream error still has to
    # reach the logs; otherwise on-call gets a DBConnection crash instead of
    # the Voyage status that caused it.
    Logger.error(
      "embed_poisoned",
      Metadata.with_category(:error, :search,
        user_id: note.user_id,
        vault_id: note.vault_id,
        note_id: note.id,
        error_kind: error_kind,
        status: status,
        detail: Metadata.upstream_error(reason),
        cooldown_seconds: cooldown
      )
    )

    # Tenant-scoped: `notes` carries FORCE ROW LEVEL SECURITY, and an UPDATE is
    # FILTERED by the policy's USING clause rather than rejected — it reports 0
    # rows with no error. Unscoped, the note is never parked, so
    # ReconcileEmbeddings re-enqueues this exact failing note every 5 minutes
    # and re-pays Voyage each time. `note.user_id` is in scope.
    {:ok, {count, _}} =
      Repo.with_tenant(note.user_id, fn ->
        Repo.update_all(park_query,
          set: [embed_retry_after: retry_after, embed_budget_parked: nil]
        )
      end)

    # Emitted after the write so `parked:` reports what actually happened.
    :telemetry.execute(
      [:engram, :embed, :poison],
      %{count: 1, cooldown_seconds: cooldown},
      %{
        error_kind: error_kind,
        status: status,
        note_id: note.id,
        user_id: note.user_id,
        parked: count > 0
      }
    )

    :ok
  end

  defp run_embed(note, user, vault, old_path_hmac_b64, opts) do
    case Crypto.maybe_decrypt_note_fields(note, user) do
      {:ok, decrypted_note} ->
        # If renamed, clean up old path's Qdrant points before re-indexing
        _ =
          if old_path_hmac_b64 do
            Indexing.delete_points_by_path_hmac(decrypted_note, old_path_hmac_b64)
          end

        budget =
          if opts[:budget_spent],
            do: [reserve_tokens: fn _ -> false end, release_tokens: fn _ -> :ok end],
            else: budget_opts(user, opts, Keyword.get(opts, :maintenance, false))

        # `dense?` is what Indexing actually wrote. Do NOT re-check the
        # budget here: a second read can land a DIFFERENT answer, and
        # the stamp would then disagree with the index. The stamp runs
        # inside the chunk-row transaction (`:in_commit`), with the tokens a
        # partial pass still needs.
        # The owner's plan model (`Engram.EmbedModels`): Indexing embeds
        # with it and the stamp names it, from this one read.
        model = EmbedModels.doc_model(user)

        index_opts =
          budget ++
            Keyword.take(opts, [
              :index_tier,
              :keep_dense,
              :embed_purpose,
              :embed_trigger,
              :rebuild
            ]) ++
            [
              doc_model: model,
              # `held_model`: the cheapest model among the vectors the note
              # keeps (`Indexing.held_model/2`), so kept large vectors stamp
              # large. The stamp's outcome is read back below, once the
              # transaction has committed.
              in_commit: fn count, dense?, pass ->
                outcome =
                  stamp_embed_hash(note, dense?, count, pass, :budget, pass.held_model || model)

                Process.put(@budget_parked_key, outcome == :parked)
              end
            ]

        result = index(note, decrypted_note, vault, user, index_opts, opts)
        parked? = Process.delete(@budget_parked_key) == true

        case result do
          # Parked on the bucket (not a floor pass: that is sparse by design).
          # A budget-spent backfill already knew, so it stays quiet (one event
          # per note of a former over-cap vault).
          {:ok, _count, _embedded_bytes, _dense?} ->
            if parked? and !opts[:budget_spent], do: newly_parked(note, user), else: :ok
            :ok

          # The v5 rebuild left `on` (halted, or switched off) after this job
          # was routed: no Voyage call. Re-routed a minute later, it either
          # runs again under `on`, or skips and releases the note's sweep
          # backoff (`RebuildStaleNote`), so a resume never waits on it.
          {:error, :rebuild_paused} ->
            {:snooze, 60}

          # The rebuild was about to pay Voyage twice for this content
          # (`Rebuild.park_double_pay/1`): parked until edited, not failed.
          {:error, :rebuild_double_pay} ->
            :ok

          # Voyage 429 — back off without burning an Oban attempt. Voyage's
          # paid-tier RPM is finite; without this guard five consecutive
          # rate-limit hits discard the job entirely.
          {:error, {429, _body}} ->
            :telemetry.execute(
              [:engram, :embed, :rate_limited],
              %{count: 1},
              %{user_id: note.user_id, vault_id: note.vault_id, note_id: note.id}
            )

            {:snooze, snooze_seconds_on_429()}

          # Strict mode refused the upsert (disk or memory). The vectors were
          # paid for and are retained by Indexing, so the retry reuses them
          # and the reservation stays charged: it was spent.
          {:error, :qdrant_backpressure} ->
            Qdrant.backpressure_snooze(:refused)

          # The index budget moved the note's tier while this pass was
          # planned or ran: not an embed failure. Rerun from the new tier,
          # without spending an attempt or counting toward poison parking.
          {:error, :index_tier_changed} ->
            {:snooze, 5}

          # Vector cache on and the note's cache misses exceed one pass's
          # embed budget: this pass embedded and cached its share, the next
          # finds it as hits and embeds the rest. Not a failure.
          {:error, :embed_continues} ->
            {:snooze, 1}

          # A newer edit replaced the content this pass planned from; that
          # edit's own job indexes it. Nothing failed.
          {:error, :superseded} ->
            :ok

          # A maintenance pass over budget kept the note's dense points
          # (`keep_dense`): nothing failed, and the budget sweep, not this
          # job, decides whether the note floors.
          {:error, :over_budget} ->
            :ok

          # The write is queued but not applied within its wait (Qdrant 200
          # with status "wait_timeout"), so the note is not stamped. Same as a
          # refusal: snooze without burning an attempt; the retry reuses the
          # retained vectors and the upsert is idempotent.
          {:error, :qdrant_wait_timeout} ->
            Qdrant.wait_timeout_snooze()

          # Input over the model's context window (H7): no re-send can fix
          # it. Index the note keyword-only now (zero Voyage spend) and park
          # it until its content changes, so it is findable and never loops.
          {:error, {:permanent, :input_too_long}} ->
            index_keyword_only(note, decrypted_note, vault, user)

          {:error, reason} ->
            # Per-attempt failure (Voyage non-429 / Qdrant). Previously
            # silent until the terminal discard after 5 retries — log it now
            # so the stall is visible on the first attempt, with a bounded
            # error_kind (no upstream body / token in the message).
            error_kind = Engram.Telemetry.error_kind(reason)
            status = embed_error_status(reason)

            :telemetry.execute(
              [:engram, :embed, :failed],
              %{count: 1},
              %{error_kind: error_kind, status: status}
            )

            Logger.warning(
              "embed_attempt_failed",
              Metadata.with_category(:warning, :search,
                user_id: note.user_id,
                vault_id: note.vault_id,
                note_id: note.id,
                error_kind: error_kind,
                status: status,
                detail: Metadata.upstream_error(reason)
              )
            )

            {:error, reason}
        end

      {:error, reason} ->
        DecryptFailure.log("embed_decrypt_failed", reason,
          user_id: note.user_id,
          note_id: note.id
        )

        {:error, reason}
    end
  end

  # A version rebuild under `on` re-checks the mode right before Voyage and
  # charges what it sent to the ledger (`Rebuild.spend/2`), which also parks
  # a note that drifted past its estimate. Everything else indexes as is.
  defp index(note, decrypted_note, vault, user, index_opts, opts) do
    cond do
      not Keyword.get(opts, :rebuild, false) ->
        Indexing.index_note_with_usage(decrypted_note, vault, user, index_opts)

      Rebuild.mode() == :on ->
        Rebuild.spend(note, fn ->
          Indexing.index_note_with_usage(decrypted_note, vault, user, index_opts)
        end)

      true ->
        {:error, :rebuild_paused}
    end
  end

  # Chunks are capped well under the context window, so a document should
  # never get here; if one does, it stays searchable by keyword. Logged as a
  # warning: it means that cap no longer holds.
  defp index_keyword_only(note, decrypted_note, vault, user) do
    Logger.warning(
      "embed_input_too_long_keyword_only",
      Metadata.with_category(:warning, :search,
        user_id: note.user_id,
        vault_id: note.vault_id,
        note_id: note.id
      )
    )

    opts = [
      reserve_tokens: fn _ -> false end,
      release_tokens: fn _ -> :ok end,
      in_commit: &stamp_embed_hash(note, &2, &1, &3, :too_long)
    ]

    case Indexing.index_note_with_usage(decrypted_note, vault, user, opts) do
      {:ok, _count, _bytes, _dense?} -> :ok
      # A refused reservation still runs dense when it would charge nothing
      # (index budget on, every changed chunk already known). Past the pass
      # embed budget that pass continues like any other: snooze, no attempt.
      {:error, :embed_continues} -> {:snooze, 1}
      {:error, reason} -> {:error, reason}
    end
  end

  # The `embed_retry_after` of a note indexed keyword-only because its input
  # is too long for the embed model. A date no clock reaches: the park ends
  # when the content changes (ReconcileEmbeddings sweeps an edited one), not
  # on a cooldown, since re-sending the same content 400s again.
  @parked_until_edited ~U[9999-01-01 00:00:00.000000Z]

  @doc "The `embed_retry_after` that parks a too-long note until it is edited."
  def parked_until_edited, do: @parked_until_edited

  # Optimistic lock: only set embed_hash if content_hash hasn't changed since
  # we started embedding. If it changed (concurrent edit), this is a no-op —
  # the reconciliation cron or the next debounced job will pick up the new version.
  # Also clears any embed_retry_after poison cooldown — a successful embed means
  # the note is no longer broken, and the crash guard's dead-man stamp, since
  # this runs inside the index write's transaction.
  # `pass`: what `Indexing` reports from the commit (`index_tier`, and the
  # tokens a partial pass still needs: `deferred_tokens`,
  # `next_deferred_tokens`).
  # `sparse_park`: :budget (a refused or partial reservation parks the note on
  # the Free bucket queue) or :too_long (an input over the model's window,
  # parked until the content changes).
  # `model`: the doc model the pass embedded with, stamped on a dense pass.
  # Returns `:parked` when it parked the note on the bucket, else `:ok`.
  defp stamp_embed_hash(
         note,
         dense?,
         chunk_count,
         pass,
         sparse_park,
         model \\ Indexing.embed_model()
       )

  defp stamp_embed_hash(%Note{content_hash: nil} = note, _dense?, _count, _pass, _park, _m),
    do: CrashGuard.clear(note, :ok)

  defp stamp_embed_hash(note, dense?, chunk_count, pass, sparse_park, model) do
    # `embed_hash` = "this content is indexed" (keyword and/or dense).
    # `dense_indexed_hash` = "this content has dense vectors in Qdrant".
    # Keeping them separate is what lets ReconcileEmbeddings backfill the
    # dense leg of a note that was indexed sparse-only.
    #
    # ONE rule: the dense hash is set only when dense vectors were actually
    # written. A dense pass alone is not enough — `chunk_count == 0` is
    # index_note/2's no-chunks outcome, and the pass just PURGED this note's
    # points. Stamping it anyway makes the column assert a false fact, and
    # ReconcileEmbeddings' backfill selects on `is_nil(dense_indexed_hash)`,
    # so the note would be skipped forever.
    # `chunker_version` is stamped on BOTH paths, including the sparse-only /
    # no-chunks one. It records which chunker last ran, not whether vectors were
    # written, and leaving it NULL after a successful pass would re-select the
    # note on every future sweep.
    #
    # A sparse-only pass that DID write chunks was the embed budget talking, so
    # the note is parked rather than cleared: ReconcileEmbeddings' dense
    # backfill selects indexed notes with no dense hash, and would otherwise
    # re-run it every tick.
    set =
      cond do
        # Nothing to index: the content's dense leg is complete with zero
        # vectors (Indexing reports `dense? = true` only on that branch).
        chunk_count == 0 and dense? ->
          [
            dense_indexed_hash: note.content_hash,
            embed_model: model,
            embed_retry_after: nil
          ] ++ @queue_clear

        dense? ->
          [
            dense_indexed_hash: note.content_hash,
            embed_model: model,
            embed_retry_after: nil
          ] ++ @queue_clear

        # A floor pass is sparse-only by design, not because the embed budget
        # refused it: nothing to park. ReconcileEmbeddings' dense backfill
        # skips a note with `index_tier` set (Indexing stamps it in this
        # transaction), so a cleared cooldown does not re-select it.
        pass.index_tier != nil ->
          [
            dense_indexed_hash: nil,
            embed_model: nil,
            embed_retry_after: nil
          ] ++ @queue_clear

        sparse_park == :too_long ->
          [
            dense_indexed_hash: nil,
            embed_model: nil,
            embed_retry_after: @parked_until_edited
          ] ++ @queue_clear

        true ->
          need = Map.get(pass, :deferred_tokens) || 0
          next = Map.get(pass, :next_deferred_tokens)
          [dense_indexed_hash: nil, embed_model: nil] ++ budget_park_set(note, need, next)
      end

    # A full pass encodes the current keyword version too, so it stamps both,
    # except a stamp the pass's reused points do not meet (`Rebuild.pass_stamp/2`,
    # #2199): those keep the vectors they were built with.
    # The TARGET versions, not the build's: before `INDEX_REBUILD=on` they are
    # the pins, so a note edited then keeps a pre-v5 stamp and the v5 pass
    # still rewrites it in the pass's layout and encoding (pinned avgdl).
    # Stamping the build would make the pass skip it for good. A pass that
    # reuses every vector costs it 0 Voyage tokens.
    # ponytail: read at stamp time, so an off->on flip DURING this index
    # stamps the build for a pass that did not use the pinned avgdl; capture
    # the target before indexing if that window ever matters.
    {chunker, keyword} = Rebuild.pass_stamp(note, Map.get(pass, :reused, 0) > 0)

    set =
      [
        embed_hash: note.content_hash,
        chunker_version: chunker,
        keyword_version: keyword,
        # A full pass read the frontmatter under the current key alias table.
        key_alias_version: Engram.Notes.KeyAliases.version()
      ] ++ set

    # Tenant-scoped: same filtered-UPDATE class as `maybe_mark_poison/3`.
    # Unscoped this stamps NOTHING, so the note re-embeds on every sweep and
    # pays Voyage each time, while `count == 0` below is logged as a benign
    # "concurrent edit" — a silent, recurring bill.
    {:ok, {count, _}} =
      Repo.with_tenant(note.user_id, fn ->
        from(n in Note,
          where: n.id == ^note.id and n.content_hash == ^note.content_hash
        )
        |> Repo.update_all(set: set)
      end)

    if count == 0 do
      Logger.debug(
        "embed_hash stamp skipped (concurrent edit)",
        Metadata.with_category(:debug, :search, note_id: note.id)
      )
    end

    :ok = CrashGuard.clear(note, :ok)
    if count > 0 and Keyword.get(set, :embed_budget_parked) == true, do: :parked, else: :ok
  end

  @doc """
  Build a debounced EmbedNote job — embed only once the note has been quiet.

  Trailing debounce: each edit re-inserts with `replace: [:scheduled_at]`, which
  pushes the run time to `now + settle` (default 30s, `EMBED_SETTLE_SECONDS`), so
  a burst of rapid saves collapses into a single Voyage call after the editing
  settles.

  Max-wait ceiling: a note edited continuously would otherwise never embed (the
  timer keeps resetting). `insert_debounced/3` clamps `scheduled_at` to
  `burst_start + max_wait` (default 5m, `EMBED_SETTLE_MAX_WAIT_SECONDS`), where
  `burst_start` is the surviving job's `inserted_at` (unchanged by `replace`).
  The unique `period` is widened to span the whole window so dedup holds until
  the ceiling fires. Inserting this changeset directly skips the clamp.

  Pass `old_path_hmac:` (base64) when the note was renamed — the worker will
  delete old-path Qdrant points before re-indexing under the new path. T3.2:
  HMAC bytes (not plaintext path) are what survives in `oban_jobs.args` JSONB.

  Bulk callers enqueue this via `Oban.insert_all`, which ignores
  `unique`/`replace`, so the ceiling is meaningless there and building the
  changeset reads nothing.
  """
  # `user_id` REQUIRED and positional — see the note on
  # `Engram.Workers.ExtractNoteLinks.new_debounced/2`.
  # The `is_binary(user_id)` guard is load-bearing, not decoration. `opts` keeps
  # a default, so `/2` still exists — without the guard
  # `new_debounced(note_id, priority: 0)` compiles cleanly and writes a KEYWORD
  # LIST into `args.user_id`, which then fails the `is_binary` check in
  # `fetch_note_for_worker_job/1` and silently takes the unscoped legacy path.
  def new_debounced(note_id, user_id, opts \\ []) when is_binary(user_id) do
    scheduled_at = DateTime.add(DateTime.utc_now(), settle_seconds(), :second)

    args = %{note_id: note_id, user_id: user_id}

    args =
      if opts[:old_path_hmac],
        do: Map.put(args, :old_path_hmac, opts[:old_path_hmac]),
        else: args

    # The oldest parked note, woken with only what is left after the notes
    # that fit (`ReconcileEmbeddings`): its pass may spend no more than this.
    args = if opts[:budget_cap], do: Map.put(args, :budget_cap, opts[:budget_cap]), else: args

    new(
      args,
      scheduled_at: scheduled_at,
      priority: Keyword.get(opts, :priority, 0),
      replace: [:scheduled_at],
      # Override the worker default (60s) so dedup spans the full settle+ceiling
      # window — otherwise a burst longer than the period spawns a second job and
      # resets the ceiling.
      unique: [
        period: settle_max_wait_seconds() + settle_seconds(),
        keys: [:note_id],
        states: :incomplete
      ]
    )
  end

  @doc """
  Drop note ids that already have an in-flight `EmbedNote` job.

  `unique:` is enforced by Oban's `insert/3` advisory lock. Bulk callers use
  `Oban.insert_all/2`, and **the basic engine ignores `unique` there** — bulk
  unique is an Oban Pro (Smart Engine) feature. So every bulk enqueue site is
  free to stack a second job onto a note that already has one pending.

  On its own that is a duplicate. Combined with `ReconcileEmbeddings` it is a
  ratchet: that worker selects notes whose `embed_hash != content_hash` and
  whose cooldown has lapsed, and never asks whether a job is already pending
  (its own comment assumed "EmbedNote is uniq-deduped"). A note whose job is
  stuck therefore collects one more job per backoff window, forever. Measured
  in dev on 2026-08-25: 61,536 pending jobs for 4,266 notes, one note queued
  184 times across five days, which then kept the backlog from ever draining.

  The lookup is `Engram.Jobs.reject_pending/3`, shared by every bulk
  enqueue site: chunked, index-backed, one query per 50 ids. Still far cheaper
  than one lookup per note.

  Suppressing a more urgent enqueue would invert `priority_for/1`, which is the
  whole fairness mechanism: during an import every note holds a pending
  backfill job (priority 9), so a live edit — priority 0 — would be swallowed
  and inherit position behind the entire backlog, the exact outcome that
  function exists to prevent. So `new_priority` PROMOTES a pending job that is
  ranked worse than the incoming one rather than dropping the enqueue on the
  floor. Oban fetches `priority ASC`, so lowering the number is the promotion.
  That keeps the "at most one pending job per note" invariant while preserving
  the jump-the-queue behaviour.

  Not a uniqueness guarantee: two bulk callers racing between this read and
  their inserts can still produce two jobs, and an `executing` job never
  suppresses: a running job may already have read the previous content, so a
  fresh edit genuinely needs its own job. Both are bounded and self-correcting —
  the extra job is a no-op once `embed_hash` is stamped — which is the whole
  difference between a duplicate and a ratchet.
  """
  @spec reject_already_queued([Ecto.UUID.t()], non_neg_integer()) :: [Ecto.UUID.t()]
  def reject_already_queued(note_ids, new_priority \\ 0),
    do:
      Engram.Jobs.reject_pending(__MODULE__, note_ids, executing: false, promote_to: new_priority)

  @backfill_priority 9

  @doc """
  Oban priority for backfill work. Oban fetches `priority ASC`, so a higher
  number loses every tie to an interactive job.

  9 is the lowest the `oban_jobs` schema allows (`non_negative_priority` checks
  `>= 0`; Oban caps the usable range at 9). Nothing else in the codebase sets a
  priority, so every other job is 0 and outranks these.
  """
  @spec backfill_priority() :: pos_integer()
  def backfill_priority, do: @backfill_priority

  @doc """
  Priority for a note's embed job, from the note itself.

  A note that has **never** been embedded (`embed_hash` nil) is bulk work: a
  first sync, an import, a restore. A note being RE-embedded has been searchable
  before and a user is waiting on their edit showing up, so it is interactive.

  This is the whole fairness mechanism, and it deliberately needs no burst
  detection, no per-user counter, and no new state — the discriminator is a
  column already in hand at every enqueue site.

  Why it matters: Oban is otherwise pure FIFO (nothing in this codebase set a
  priority before). One user importing a 50k-note vault would put 50k jobs
  ahead of every other user's live edit, so nobody's edits become searchable
  until that import drains — hours. With this split, a live edit jumps the
  entire backlog.

  Note that low priority is NOT deferral: a demoted job runs immediately when
  nothing else is queued. It only yields under contention, which is exactly
  when yielding is correct. That is why demoting a genuinely-new note (a fresh
  note in an idle system) costs nothing.
  """
  @spec priority_for(Note.t()) :: non_neg_integer()
  def priority_for(%Note{embed_hash: nil}), do: @backfill_priority
  def priority_for(%Note{}), do: 0

  defp settle_seconds, do: Application.get_env(:engram, :embed_settle_seconds, 30)

  defp settle_max_wait_seconds,
    do: Application.get_env(:engram, :embed_settle_max_wait_seconds, 300)

  @doc """
  Inserts `new_debounced/3` through `Engram.Notes.Enqueue`, clamped to the
  max-wait ceiling.

  The burst start is read off the job Oban's own unique check returns (the
  surviving job, `conflict?: true`, after its `replace`), so the clamp costs no
  extra read. Only when the replaced `scheduled_at` overshoots the ceiling does
  one UPDATE pull it back: a continuously-edited note, once per edit past the
  5-minute mark.

  Race: a concurrent enqueue for the same note can replace `scheduled_at`
  between Oban's update and this one. That only moves the embed by at most one
  settle interval (never earlier than the ceiling, never a duplicate), and the
  next edit self-corrects. Bounded extra staleness, not a correctness bug.
  """
  @spec insert_debounced(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def insert_debounced(note_id, user_id, opts \\ []) do
    note_id
    |> new_debounced(user_id, opts)
    |> Engram.Notes.Enqueue.enqueue("embed_note", &insert_clamped/1)
  end

  defp insert_clamped(changeset) do
    case Oban.insert(changeset) do
      # `id` is nil when Oban could not take the unique lock and returned the
      # unsaved changeset as the conflict: nothing to clamp.
      {:ok, %Oban.Job{conflict?: true, id: id, inserted_at: %DateTime{} = start} = job}
      when is_integer(id) ->
        {:ok, clamp_to_ceiling(job, DateTime.add(start, settle_max_wait_seconds(), :second))}

      other ->
        other
    end
  end

  defp clamp_to_ceiling(%Oban.Job{id: id, scheduled_at: at} = job, ceiling) do
    if DateTime.compare(at, ceiling) == :gt do
      {_, _} =
        Repo.update_all(from(j in Oban.Job, where: j.id == ^id), set: [scheduled_at: ceiling])

      %{job | scheduled_at: ceiling}
    else
      job
    end
  end
end
