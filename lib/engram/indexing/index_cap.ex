defmodule Engram.Indexing.IndexCap do
  @moduledoc """
  Per-user cap on how many notes get indexed for search.

  This caps what is **indexed**, never what **syncs**. A user's whole vault
  always syncs; only the first N notes become searchable. Capping sync would
  leave a half-synced vault on first sync, which reads as "Engram is broken"
  rather than "Engram is limited" — see the pricing decision log.

  Rank is server-side creation time among **live** notes, so deleting a note
  frees a slot. The consequence is that a user's NEWEST work is what falls
  outside the cap, which is why `counts/1` exists: the number is surfaced in the
  UI rather than letting note 2001 silently return nothing.
  """

  import Ecto.Query

  alias Engram.Billing
  alias Engram.Billing.LimitKeys
  alias Engram.Logger.Metadata
  alias Engram.Notes.Chunk
  alias Engram.Notes.Note
  alias Engram.Repo

  require Logger

  @doc """
  True when this note is inside the user's indexed-note cap.

  Uncapped tiers (`nil` / `:unlimited`) short-circuit without touching the DB —
  this runs on every index, so the paid path must stay free.
  """
  @spec within_cap?(Note.t()) :: boolean()
  def within_cap?(%Note{} = note) do
    user = Engram.Accounts.get_user!(note.user_id)

    case resolve_cap(user) do
      {:cap, cap} -> rank_below_cap?(note, cap)
      :unlimited -> true
    end
  end

  @doc """
  `%{indexed: n, total: m}` live notes for a user — what the UI renders as
  "2,000 of 4,312 notes indexed".

  `indexed` is `min(total, cap)`, not a count of rows actually in Qdrant. That
  is deliberate: the true count lags by the Oban queue depth, so reporting it
  would make the number drift during a bulk import and read as data loss. The
  cap is the contract; the queue is an implementation detail.
  """
  @spec counts(map()) :: %{indexed: non_neg_integer(), total: non_neg_integer()}
  def counts(user) do
    total = live_note_count(user.id)

    indexed =
      case resolve_cap(user) do
        {:cap, cap} -> min(total, cap)
        :unlimited -> total
      end

    %{indexed: indexed, total: total}
  end

  @doc """
  Re-opens indexing for notes that a deletion just brought inside the cap.

  Deleting a note frees a slot, but the note that inherits it already carries a
  stamped `embed_hash` from the pass that skipped it — so neither `EmbedNote`
  nor `ReconcileEmbeddings` would ever look at it again, and it would stay
  unsearchable until the user happened to edit it.

  Nulling `embed_hash` puts it back in the reconcile cron's normal stale-note
  query, which re-indexes it at backfill priority. No new worker, no new state.

  Scoped to in-cap notes that have no chunk rows, so it is a no-op for anyone
  already fully indexed and for every uncapped tier.
  """
  @spec backfill_freed_slots(Ecto.UUID.t()) :: :ok
  def backfill_freed_slots(user_id) when is_binary(user_id) do
    user = Engram.Accounts.get_user!(user_id)

    case resolve_cap(user) do
      {:cap, cap} ->
        in_cap =
          from(n in Note,
            where: n.user_id == ^user_id and n.kind == "note" and is_nil(n.deleted_at),
            order_by: [asc: n.created_at, asc: n.id],
            limit: ^cap,
            select: n.id
          )

        # Notes with zero chunk rows are the ones a prior pass skipped for the
        # cap; anything already indexed is left alone.
        unindexed =
          from(n in Note,
            as: :n,
            where: n.id in subquery(in_cap),
            where: not exists(from(c in Chunk, where: c.note_id == parent_as(:n).id, select: 1)),
            select: n.id
          )

        {count, _} =
          from(n in Note, where: n.kind == "note" and n.id in subquery(unindexed))
          |> Repo.update_all([set: [embed_hash: nil]], skip_tenant_check: true)

        if count > 0 do
          :telemetry.execute(
            [:engram, :indexing, :cap_slots_freed],
            %{count: count},
            %{user_id: user_id}
          )
        end

        :ok

      :unlimited ->
        :ok
    end
  end

  @doc """
  Drops a user's dense vectors after they lose semantic entitlement.

  Without this a downgraded user keeps every dense vector in Qdrant forever —
  ~$0.53/mo of RAM on a tier priced at $0.11 — which is exactly the
  accumulation problem the keyword-only tier exists to fix.

  Nulls BOTH hashes rather than just `dense_indexed_hash`: with only the dense
  one cleared, `EmbedNote`'s skip clause sees `embed_hash == content_hash` and a
  now-unentitled user, and correctly does nothing. Clearing `embed_hash` too
  puts the notes back in the reconcile cron's stale query, and because
  `commit_index/1` deletes a note's points before inserting the new ones, the
  rebuild replaces dense+sparse points with sparse-only ones. The vectors go
  away as a side effect of normal re-indexing.
  """
  @spec revoke_dense_index(Ecto.UUID.t()) :: :ok
  def revoke_dense_index(user_id) when is_binary(user_id) do
    {count, _} =
      from(n in Note,
        where: n.user_id == ^user_id and n.kind == "note" and is_nil(n.deleted_at),
        where: not is_nil(n.dense_indexed_hash)
      )
      |> Repo.update_all([set: [embed_hash: nil, dense_indexed_hash: nil]],
        skip_tenant_check: true
      )

    if count > 0 do
      :telemetry.execute(
        [:engram, :indexing, :dense_revoked],
        %{count: count},
        %{user_id: user_id}
      )
    end

    :ok
  end

  @doc """
  Resolves `:indexed_notes_cap` to `{:cap, n}` or `:unlimited`.

  The ONE place this key is interpreted, so the three call sites cannot drift.
  Public because the fail-CLOSED behaviour on a malformed value is a contract
  worth pinning directly: at small note counts a capped user and an uncapped
  one are behaviourally identical, so no test of `within_cap?/1` or `counts/1`
  can tell them apart.

  `nil` (starter/pro) and `:unlimited` (self-host) are the only values that
  mean uncapped, plus a NEGATIVE integer — the codebase-wide `unlimited`
  sentinel that `check_limit/3` and `normalize_capability/2` use and that the
  e2e overrides rely on. Without the negative clause `rank < -1` is false for
  every note and NOTHING is indexed.

  Everything else falls back to the tier DEFAULT rather than to unlimited.
  That is the conservative FLOOR, deliberately not the configured value: the
  malformed value can come from any layer of the resolver (user override, env
  override, or the plan row's JSONB), so there is no well-defined layer to
  "skip". Falling to the floor can only ever be more restrictive than what was
  configured, which is the safe direction for a cost cap — but it does mean an
  operator who set `ENGRAM_FREE_INDEXED_NOTES_CAP=10000` alongside a malformed
  per-user override silently gets 2,000. The warning below is the only signal;
  the real fix is validating these values at the WRITE boundary.
  `effective_limit/2` reads overrides straight out of untyped JSONB, so a
  hand-written `%{"v" => "500"}` or a float from a JSON round-trip reaches
  here; treating those as "no cap" would silently uncap the one key that
  exists to bound Qdrant spend. Same fail-CLOSED rule as
  `Billing.attachments_all_types?/1`.
  """
  @spec resolve_cap(map()) :: {:cap, non_neg_integer()} | :unlimited
  def resolve_cap(user) do
    case Billing.effective_limit(user, :indexed_notes_cap) do
      cap when is_integer(cap) and cap >= 0 -> {:cap, cap}
      cap when is_integer(cap) -> :unlimited
      nil -> :unlimited
      :unlimited -> :unlimited
      other -> fallback_cap(user, other)
    end
  end

  defp fallback_cap(user, other) do
    Logger.warning(
      "indexed_notes_cap resolved to a non-integer; falling back to the tier default",
      Metadata.with_category(:warning, :search,
        user_id: user.id,
        value_type: inspect(other) |> String.slice(0, 40)
      )
    )

    case LimitKeys.default_for(:indexed_notes_cap, Billing.tier(user)) do
      cap when is_integer(cap) and cap >= 0 -> {:cap, cap}
      _ -> :unlimited
    end
  end

  # True when fewer than `cap` live notes are older than this one.
  #
  # Deliberately a BOUNDED count, not `count(*)`: this runs once per indexed
  # note, so an unbounded rank scan makes a bulk import O(N^2) — 1,000 notes
  # meant 1,000 full scans over a growing table, which timed out the 120s
  # bulk-first-sync e2e. `LIMIT cap` caps each scan at `cap` index rows no
  # matter how large the vault is, and the common case (a user well under the
  # cap) stops early because there simply are not that many older rows.
  #
  # An earlier version short-circuited on `usage_meters.notes_count`, which is
  # O(1) — but that counter is maintained at only three call sites, and an
  # UNDER-count silently admits everything. Wrong direction for a billing cap,
  # and worst exactly during a bulk import. The source of truth stays the rows.
  #
  # Ties on created_at break by id so the rank is stable rather than flapping
  # between two notes written in the same microsecond, which is common during a
  # bulk first sync.
  defp rank_below_cap?(%Note{} = note, cap) do
    older =
      from(n in Note,
        where: n.user_id == ^note.user_id and n.kind == "note" and is_nil(n.deleted_at),
        where:
          n.created_at < ^note.created_at or
            (n.created_at == ^note.created_at and n.id < ^note.id),
        order_by: [asc: n.created_at, asc: n.id],
        limit: ^cap,
        select: n.id
      )

    count =
      Repo.one(from(o in subquery(older), select: count(o.id)), skip_tenant_check: true) || 0

    count < cap
  end

  defp live_note_count(user_id) do
    Repo.one(
      from(n in Note,
        where: n.user_id == ^user_id and n.kind == "note" and is_nil(n.deleted_at),
        select: count(n.id)
      ),
      skip_tenant_check: true
    ) || 0
  end
end
