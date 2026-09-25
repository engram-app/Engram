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
  # Takes the caller's `%User{}` when it has one. This runs on EVERY index and
  # the caller (`Indexing.prepare_index/3`) has already resolved the same row,
  # so fetching our own made the "must stay free" claim above false by one
  # `users` query per note — and one `subscriptions` query too, since a bare
  # `get_user!/1` struct has no association loaded for `effective_limit/2` to
  # read. See #1502.
  @spec within_cap?(Note.t(), Engram.Accounts.User.t() | nil) :: boolean()
  def within_cap?(%Note{} = note, user \\ nil) do
    user = user || Engram.Accounts.get_user!(note.user_id)

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

  An uncapped user gets `%{indexed: 0, total: 0}` and is never counted — see
  the comment on the `:unlimited` branch. Callers must read this as the
  `indexed < total` question only; it is not a vault size.
  """
  @spec counts(map()) :: %{indexed: non_neg_integer(), total: non_neg_integer()}
  def counts(user) do
    case resolve_cap(user) do
      {:cap, cap} ->
        total = live_note_count(user.id)
        %{indexed: min(total, cap), total: total}

      # Resolve the cap BEFORE counting, and for an uncapped user do not count
      # at all. `counts/1` is wired into `/bootstrap`, which runs on every page
      # load and every tab, and `live_note_count/1`'s predicate is a whole-vault
      # aggregate — an 80k-note Pro user paid for three of them to open three
      # tabs, to populate a banner their tier never renders.
      #
      # Equal values are the COMPLETE answer here: the sole consumer asks
      # `indexed < total` (see `search-panel.tsx`), which is false either way
      # for someone with no cap. Zeros rather than a fabricated vault size, so
      # nothing downstream can mistake this for a measurement we did not take.
      :unlimited ->
        %{indexed: 0, total: 0}
    end
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

        # `with_tenant` for the same reason as `evict_over_cap/1`: `notes`
        # carries FORCE ROW LEVEL SECURITY, and an UPDATE is FILTERED by the
        # policy's USING clause rather than rejected. Unscoped this reports
        # `{0, nil}`, skips the telemetry below on its `count > 0` guard, and
        # returns `:ok` having freed no cap slots at all — so a user who
        # deleted notes to make room stays stuck at their cap with no error
        # anywhere.
        #
        # Only INSERTs raise 42501, which is why this site outlived the
        # read-side fix in 1f336bfa.
        #
        # The query builders above are pure Ecto structs and touch no
        # connection, so only the write needs the tenant scope.
        {:ok, {count, _}} =
          Repo.with_tenant(user_id, fn ->
            from(n in Note, where: n.kind == "note" and n.id in subquery(unindexed))
            |> Repo.update_all([set: [embed_hash: nil]], skip_tenant_check: true)
          end)

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
  Re-opens the notes a downgrade just pushed outside the cap.

  The mirror of `backfill_freed_slots/1`. A Pro->Free downgrade leaves every
  note indexed, and nothing re-checks the cap until a note is re-indexed, so
  the notes past the new cap (the NEWEST ones, by `created_at`) would stay
  searchable forever. Nulling both hashes puts them back in the reconcile
  cron's stale-note query; the re-index finds them outside the cap and purges
  their points.

  Only notes past the cap that still have chunk rows are touched. Notes inside
  the cap keep their dense vectors — semantic search is every tier's, so a
  rebuild there would buy nothing.
  """
  @spec evict_over_cap(Ecto.UUID.t()) :: :ok
  def evict_over_cap(user_id) when is_binary(user_id) do
    user = Engram.Accounts.get_user!(user_id)

    case resolve_cap(user) do
      {:cap, cap} ->
        over_cap =
          from(n in Note,
            where: n.user_id == ^user_id and n.kind == "note" and is_nil(n.deleted_at),
            order_by: [asc: n.created_at, asc: n.id],
            offset: ^cap,
            select: n.id
          )

        indexed =
          from(n in Note,
            as: :n,
            where: n.id in subquery(over_cap),
            where: exists(from(c in Chunk, where: c.note_id == parent_as(:n).id, select: 1)),
            select: n.id
          )

        # `with_tenant`: `notes` carries FORCE ROW LEVEL SECURITY, and an UPDATE
        # is FILTERED by the policy rather than rejected — unscoped this reports
        # `{0, nil}` and returns `:ok` having evicted nothing, so a downgraded
        # user keeps searching past the cap with no error anywhere.
        {:ok, {count, _}} =
          Repo.with_tenant(user_id, fn ->
            from(n in Note, where: n.kind == "note" and n.id in subquery(indexed))
            |> Repo.update_all([set: [embed_hash: nil, dense_indexed_hash: nil]],
              skip_tenant_check: true
            )
          end)

        if count > 0 do
          :telemetry.execute(
            [:engram, :indexing, :over_cap_evicted],
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

    # `with_tenant` rather than `skip_tenant_check`: `notes` carries FORCE ROW
    # LEVEL SECURITY, and skipping the app-level guard does NOT set
    # `app.current_tenant` — the policy then compares against NULL and filters
    # every row. A zero here computes `0 < cap` and admits the note, so the
    # failure is PERMISSIVE: every capped user silently over-indexes. Dev and
    # CI cannot catch it because their superuser bypasses FORCE RLS.
    #
    # `with_tenant` is re-entrant for the same tenant, so a caller already
    # holding the tenant pays nothing; only the tenant-less indexing path
    # opens the short transaction.
    {:ok, count} =
      Repo.with_tenant(note.user_id, fn ->
        Repo.one(from(o in subquery(older), select: count(o.id))) || 0
      end)

    count < cap
  end

  defp live_note_count(user_id) do
    # Same FORCE RLS reasoning as rank_below_cap?/2. A tenant-less read returns
    # 0, and `/bootstrap` then renders "0 of 0 notes indexed" to a user whose
    # vault is full — the exact support ticket the cap banner exists to avoid.
    {:ok, count} =
      Repo.with_tenant(user_id, fn ->
        Repo.one(
          from(n in Note,
            where: n.user_id == ^user_id and n.kind == "note" and is_nil(n.deleted_at),
            select: count(n.id)
          )
        ) || 0
      end)

    count
  end
end
