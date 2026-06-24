defmodule Engram.Workers.EmbedNote do
  @moduledoc """
  Oban worker: embeds a note and upserts to Qdrant.

  Debounce: 5-second scheduled_at delay, replaced on re-insert so rapid edits
  trigger only one Voyage API call.

  Dedup: unique per note_id in available/scheduled states, 60-second window.

  Idempotency: skips embedding when embed_hash already matches content_hash
  (content hasn't changed since last successful embed). On success, sets
  embed_hash = content_hash using an optimistic lock — if content changed
  mid-embed, the update is a no-op and the next job picks up the new version.
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
  alias Engram.Billing
  alias Engram.Crypto
  alias Engram.Crypto.RotationGate
  alias Engram.Indexing
  alias Engram.Logger.DecryptFailure
  alias Engram.Logger.Metadata
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.UsageMeters
  alias Engram.Vaults.Vault

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    note_id = args["note_id"]
    # T3.2 — `old_path_hmac` is a base64-encoded HMAC, never plaintext path.
    old_path_hmac_b64 = args["old_path_hmac"]

    # skip_tenant_check: trusted internal worker — queries already scoped to note_id/user_id
    case Repo.get(Note, note_id, skip_tenant_check: true) do
      nil ->
        {:discard, "note #{note_id} not found"}

      %Note{deleted_at: deleted_at} when deleted_at != nil ->
        {:discard, "note #{note_id} is soft-deleted"}

      %Note{content_hash: hash, embed_hash: hash}
      when hash != nil and is_nil(old_path_hmac_b64) ->
        # Already embedded this exact content and no rename pending — skip
        :ok

      note ->
        # T3.7 — gate writes during DEK rotation. The worker may have been
        # enqueued before the lock was acquired; re-check the live row.
        case RotationGate.check(note.user_id) do
          {:error, :rotation_in_progress} ->
            :telemetry.execute(
              [:engram, :crypto, :rotate, :dek, :gate_blocked],
              %{count: 1},
              %{gate_path: :worker, op: :embed_note}
            )

            {:snooze, 60}

          {:error, :user_not_found} ->
            {:discard, :user_deleted}

          :ok ->
            case phone_gate(note.user_id) do
              :ok ->
                case embed_budget_gate(note) do
                  :ok ->
                    case run_embed(note, old_path_hmac_b64) do
                      :ok ->
                        _ = record_embed_tokens(note)
                        :ok

                      other ->
                        other
                    end

                  {:cancel, reason} ->
                    {:cancel, reason}
                end

              {:snooze, secs} ->
                {:snooze, secs}
            end
        end
    end
  end

  # Voyage/Qdrant non-2xx surface as {status, body}; pull the bounded HTTP
  # status (401 vs 429 vs 500 vs 503 is the on-call triage signal). nil for a
  # transport error (timeout/closed), which error_kind names by struct instead.
  defp embed_error_status({status, _body}) when is_integer(status), do: status
  defp embed_error_status(_), do: nil

  # Pricing v2 §A — block embeds for unverified-phone users when the gate is
  # enabled. Default false so self-host and pre-launch cloud are unaffected.
  defp phone_gate(user_id) do
    if Application.get_env(:engram, :require_phone_for_embed, false) do
      case Accounts.get_user(user_id) do
        %{phone_verified_at: nil} ->
          :telemetry.execute(
            [:engram, :abuse, :embed_blocked_no_phone],
            %{count: 1},
            %{user_id: user_id}
          )

          {:snooze, 3600}

        %{} ->
          :ok

        nil ->
          :ok
      end
    else
      :ok
    end
  end

  # Pricing v2 §B — block embeds when the user has exhausted their lifetime
  # token budget. Resolver returns nil for Starter/Pro (unmetered), so this is
  # effectively Free-only. Per-user overrides via Billing.UserLimitOverride.
  defp embed_budget_gate(%Note{user_id: user_id} = note) do
    user = Accounts.get_user!(user_id)
    current = UsageMeters.lifetime_embed_tokens(user_id)
    estimated = estimate_note_tokens(note)

    case Billing.check_limit(user, :lifetime_embed_token_cap, current + estimated - 1) do
      :ok ->
        :ok

      {:error, :limit_reached} ->
        :telemetry.execute(
          [:engram, :abuse, :embed_budget_exhausted],
          %{count: 1, lifetime_tokens: current},
          %{user_id: user_id}
        )

        Logger.warning(
          "EmbedNote rejected — lifetime embed-token cap reached",
          Metadata.with_category(:warning, :search,
            user_id: user_id,
            reason_label: :embed_budget_exhausted
          )
        )

        {:cancel, :embed_budget_exhausted}
    end
  end

  defp record_embed_tokens(%Note{user_id: user_id} = note) do
    case estimate_note_tokens(note) do
      0 -> :ok
      tokens -> UsageMeters.add_embed_tokens(user_id, tokens)
    end
  end

  # Token estimate uses the ciphertext byte size. AES-GCM adds a 16-byte
  # auth tag so we over-count by ~4 tokens per note, which keeps the cap
  # conservative. Real `usage.total_tokens` from the Voyage response is a
  # follow-up.
  defp estimate_note_tokens(%Note{content_ciphertext: ct}) when is_binary(ct) do
    UsageMeters.estimate_tokens(ct)
  end

  defp estimate_note_tokens(_), do: 0

  # Snooze duration after Voyage 429. Env-driven via `EMBED_429_SNOOZE_SECONDS`
  # (wired in runtime.exs) so we can tune as Voyage RPM allotment grows. 60s is
  # the right default for free-tier (3 RPM) and a safe ceiling for paid tier.
  defp snooze_seconds_on_429 do
    Application.get_env(:engram, :embed_429_snooze_seconds, 60)
  end

  defp run_embed(note, old_path_hmac_b64) do
    user = Accounts.get_user!(note.user_id)

    # Load vault up front so we can drive both the decrypt path (future) and
    # the index call. skip_tenant_check: trusted internal worker.
    # Missing vault means the note is orphaned — nothing to index, discard.
    case Repo.get(Vault, note.vault_id, skip_tenant_check: true) do
      nil ->
        {:discard, "vault #{note.vault_id} not found for note #{note.id}"}

      %Vault{} = vault ->
        case Crypto.maybe_decrypt_note_fields(note, user) do
          {:ok, decrypted_note} ->
            # If renamed, clean up old path's Qdrant points before re-indexing
            _ =
              if old_path_hmac_b64 do
                Indexing.delete_points_by_path_hmac(decrypted_note, old_path_hmac_b64)
              end

            case Indexing.index_note(decrypted_note, vault) do
              {:ok, _count} ->
                stamp_embed_hash(note)
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
                    status: status
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
  end

  # Optimistic lock: only set embed_hash if content_hash hasn't changed since
  # we started embedding. If it changed (concurrent edit), this is a no-op —
  # the reconciliation cron or the next debounced job will pick up the new version.
  defp stamp_embed_hash(%Note{content_hash: nil}), do: :ok

  defp stamp_embed_hash(note) do
    {count, _} =
      from(n in Note,
        where: n.id == ^note.id and n.content_hash == ^note.content_hash
      )
      |> Repo.update_all([set: [embed_hash: note.content_hash]], skip_tenant_check: true)

    if count == 0 do
      Logger.debug(
        "embed_hash stamp skipped (concurrent edit)",
        Metadata.with_category(:debug, :search, note_id: note.id)
      )
    end

    :ok
  end

  @doc """
  Build a debounced EmbedNote job — embed only once the note has been quiet.

  Trailing debounce: each edit re-inserts with `replace: [:scheduled_at]`, which
  pushes the run time to `now + settle` (default 30s, `EMBED_SETTLE_SECONDS`), so
  a burst of rapid saves collapses into a single Voyage call after the editing
  settles.

  Max-wait ceiling: a note edited continuously would otherwise never embed (the
  timer keeps resetting). We clamp `scheduled_at` to `burst_start + max_wait`
  (default 5m, `EMBED_SETTLE_MAX_WAIT_SECONDS`), where `burst_start` is the
  surviving job's `inserted_at` (unchanged by `replace`). The unique `period` is
  widened to span the whole window so dedup holds until the ceiling fires.

  Pass `old_path_hmac:` (base64) when the note was renamed — the worker will
  delete old-path Qdrant points before re-indexing under the new path. T3.2:
  HMAC bytes (not plaintext path) are what survives in `oban_jobs.args` JSONB.
  """
  def new_debounced(note_id, opts \\ []) do
    quiet_at = DateTime.add(DateTime.utc_now(), settle_seconds(), :second)
    scheduled_at = clamp_to_ceiling(note_id, quiet_at)

    args = %{note_id: note_id}

    args =
      if opts[:old_path_hmac],
        do: Map.put(args, :old_path_hmac, opts[:old_path_hmac]),
        else: args

    new(
      args,
      scheduled_at: scheduled_at,
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

  defp settle_seconds, do: Application.get_env(:engram, :embed_settle_seconds, 30)

  defp settle_max_wait_seconds,
    do: Application.get_env(:engram, :embed_settle_max_wait_seconds, 300)

  # Clamp the trailing-debounce target to burst_start + max_wait so a
  # continuously-edited note still embeds. nil burst_start = no pending job =
  # fresh burst, use the full settle window.
  defp clamp_to_ceiling(note_id, quiet_at) do
    case existing_burst_start(note_id) do
      nil ->
        quiet_at

      burst_start ->
        ceiling = DateTime.add(burst_start, settle_max_wait_seconds(), :second)
        if DateTime.compare(quiet_at, ceiling) == :gt, do: ceiling, else: quiet_at
    end
  end

  # inserted_at of the in-flight EmbedNote job for this note — the burst start,
  # preserved across `replace: [:scheduled_at]` re-inserts. skip_tenant_check:
  # Oban.Job is not a tenant-scoped schema.
  defp existing_burst_start(note_id) do
    from(j in Oban.Job,
      where: j.worker == "Engram.Workers.EmbedNote",
      where: fragment("? ->> 'note_id' = ?", j.args, ^to_string(note_id)),
      where: j.state in ["scheduled", "available", "executing", "retryable"],
      order_by: [asc: j.inserted_at],
      limit: 1,
      select: j.inserted_at
    )
    |> Repo.one(skip_tenant_check: true)
  end
end
