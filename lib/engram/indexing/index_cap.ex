defmodule Engram.Indexing.IndexCap do
  @moduledoc """
  Per-user cap on how many notes get DENSE (Voyage) embeddings: Free's
  `notes_cap`, so at most 3,000.

  This caps the embedding spend, never what syncs and never what is
  searchable. Notes past the cap are still indexed keyword-only (sparse BM25,
  computed locally, no Voyage call). The cap only binds a Free user who holds
  more notes than `notes_cap` allows: notes stored under the old 10,000 cap,
  or a downgraded paid account.

  Rank is server-side creation time among **live** notes, oldest first, so
  deleting a note frees a slot.
  """

  import Ecto.Query

  alias Engram.Billing
  alias Engram.Billing.LimitKeys
  alias Engram.Logger.Metadata
  alias Engram.Notes.Note
  alias Engram.Repo

  require Logger

  @doc """
  True when this note may get dense vectors.

  Uncapped users short-circuit without touching the DB. This runs on every
  index, so the paid path must stay free. Takes the caller's `%User{}` (with
  its subscription loaded) when it has one; see #1502.
  """
  @spec within_cap?(Note.t(), Engram.Accounts.User.t() | nil) :: boolean()
  def within_cap?(%Note{} = note, user \\ nil) do
    user = user || Engram.Accounts.get_user_with_subscription!(note.user_id)

    case resolve_cap(user) do
      {:cap, cap} -> rank_below_cap?(note, cap)
      :unlimited -> true
    end
  end

  @doc """
  Re-opens dense embedding for notes a deletion just brought inside the cap.

  The note that inherits a freed slot was indexed keyword-only and parked
  (`embed_budget_parked`) for 24h. Clearing the park puts it back in
  ReconcileEmbeddings' dense backfill now instead of a day later.
  """
  @spec backfill_freed_slots(Ecto.UUID.t()) :: :ok
  def backfill_freed_slots(user_id) when is_binary(user_id) do
    user = Engram.Accounts.get_user_with_subscription!(user_id)

    case resolve_cap(user) do
      {:cap, cap} ->
        in_cap =
          from(n in Note,
            where: n.user_id == ^user_id and n.kind == "note" and is_nil(n.deleted_at),
            order_by: [asc: n.created_at, asc: n.id],
            limit: ^cap,
            select: n.id
          )

        # `with_tenant`: `notes` carries FORCE ROW LEVEL SECURITY, and an
        # UPDATE is FILTERED by the policy rather than rejected. Unscoped this
        # reports `{0, nil}` and frees no slots, with no error anywhere.
        {:ok, {count, _}} =
          Repo.with_tenant(user_id, fn ->
            from(n in Note,
              where:
                n.kind == "note" and n.id in subquery(in_cap) and
                  n.embed_budget_parked == true and
                  is_nil(n.dense_indexed_hash)
            )
            |> Repo.update_all([set: [embed_retry_after: nil, embed_budget_parked: nil]],
              skip_tenant_check: true
            )
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
  Drops dense vectors from the notes a downgrade pushed past the cap.

  A Pro->Free downgrade leaves every note embedded, and nothing re-checks the
  cap until a note is re-indexed. Nulling both hashes puts the notes past the
  cap back in ReconcileEmbeddings' stale query; the re-index finds them
  outside the cap and rebuilds them keyword-only, which replaces their dense
  points. Notes inside the cap keep their vectors.
  """
  @spec evict_over_cap(Ecto.UUID.t()) :: :ok
  def evict_over_cap(user_id) when is_binary(user_id) do
    user = Engram.Accounts.get_user_with_subscription!(user_id)

    case resolve_cap(user) do
      {:cap, cap} ->
        over_cap =
          from(n in Note,
            where: n.user_id == ^user_id and n.kind == "note" and is_nil(n.deleted_at),
            order_by: [asc: n.created_at, asc: n.id],
            offset: ^cap,
            select: n.id
          )

        # `with_tenant` for the same filtered-UPDATE reason as
        # `backfill_freed_slots/1`.
        {:ok, {count, _}} =
          Repo.with_tenant(user_id, fn ->
            from(n in Note,
              where:
                n.kind == "note" and n.id in subquery(over_cap) and
                  not is_nil(n.dense_indexed_hash)
            )
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
  Resolves the embed cap to `{:cap, n}` or `:unlimited`.

  Free only: it is Free's `notes_cap`. Paid tiers are unmetered for embedding
  (their `notes_cap` bounds storage, and ranking a 50,000-note vault on every
  index would cost far more than it saves). Self-host (`limits_enforced`
  off) resolves `:unlimited` through `effective_limit/2`.

  A negative integer is the codebase-wide unlimited sentinel (e2e users lift
  `notes_cap` with it). Any other malformed value falls back to the tier
  default rather than to unlimited: the conservative direction for a cost
  cap.
  """
  @spec resolve_cap(map()) :: {:cap, non_neg_integer()} | :unlimited
  def resolve_cap(user) do
    if Billing.tier(user) == :free do
      case Billing.effective_limit(user, :notes_cap) do
        cap when is_integer(cap) and cap >= 0 -> {:cap, cap}
        cap when is_integer(cap) -> :unlimited
        nil -> :unlimited
        :unlimited -> :unlimited
        other -> fallback_cap(user, other)
      end
    else
      :unlimited
    end
  end

  defp fallback_cap(user, other) do
    Logger.warning(
      "notes_cap resolved to a non-integer; embed cap falls back to the tier default",
      Metadata.with_category(:warning, :search,
        user_id: user.id,
        value_type: inspect(other) |> String.slice(0, 40)
      )
    )

    case LimitKeys.default_for(:notes_cap, :free) do
      cap when is_integer(cap) and cap >= 0 -> {:cap, cap}
      _ -> :unlimited
    end
  end

  # True when fewer than `cap` live notes are older than this one.
  #
  # A BOUNDED count, not `count(*)`: this runs once per indexed note, so an
  # unbounded rank scan makes a bulk import O(N^2). `LIMIT cap` caps each scan
  # at `cap` index rows. Ties on created_at break by id so the rank is stable.
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

    # `with_tenant`, not `skip_tenant_check`: under FORCE RLS a tenant-less
    # read counts 0 and admits every note, so the failure is permissive and
    # invisible in dev/CI (superuser bypasses RLS).
    {:ok, count} =
      Repo.with_tenant(note.user_id, fn ->
        Repo.one(from(o in subquery(older), select: count(o.id))) || 0
      end)

    count < cap
  end
end
