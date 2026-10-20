defmodule Engram.UsageMeters do
  @moduledoc """
  Per-user usage counters that drive pricing-v2 abuse defenses.

  Lifetime embed-token counter: monotonic, never decremented on note delete.
  It no longer gates anything (analytics reads it); Free's embed budget is the
  refilling bucket below (`bucket_take/4`).

  Lazy-initialized: rows are inserted on first write via `add_embed_tokens/2`.
  Reads return zero for users without a row yet.
  """

  import Ecto.Query

  alias Engram.Cache
  alias Engram.Repo

  # Activity-stamp debounce window; the `:activity` cache holds the last stamp.
  @debounce_seconds 3600

  defmodule Meter do
    use Ecto.Schema

    # PK-as-uuid exception: this table is keyed on `user_id`, not `id`,
    # so it can't use `Engram.Schema` (which forces id-as-PK). Mirror the
    # macro's effect by hand: PK type is `Ecto.UUID` (app/server-supplied,
    # no autogenerate) and FK type is `Ecto.UUID` for any future belongs_to.
    @primary_key {:user_id, Ecto.UUID, autogenerate: false}
    @foreign_key_type Ecto.UUID
    schema "usage_meters" do
      field :lifetime_embed_tokens, :integer, default: 0
      field :notes_count, :integer, default: 0
      field :embed_bucket_tokens, :float
      field :embed_bucket_at, :utc_datetime_usec
      field :last_active_at, :utc_datetime_usec
      field :updated_at, :utc_datetime_usec
    end
  end

  @doc """
  One read of every counter this user is metered on, for the usage endpoint.

  The conversation counters are gone: `ai_searches_per_day` replaced them and
  lives in the cluster-synced ETS limiter, which has no read-without-spend API.
  Returns zeroes for a user with no row yet (rows are lazy-initialized).
  """
  @spec snapshot(Ecto.UUID.t()) :: %{
          notes: non_neg_integer(),
          lifetime_embed_tokens: non_neg_integer()
        }
  def snapshot(user_id) when is_binary(user_id) do
    case Repo.one(from(m in Meter, where: m.user_id == ^user_id), skip_tenant_check: true) do
      nil -> %{notes: 0, lifetime_embed_tokens: 0}
      %Meter{} = m -> %{notes: m.notes_count, lifetime_embed_tokens: m.lifetime_embed_tokens}
    end
  end

  @spec lifetime_embed_tokens(Ecto.UUID.t()) :: non_neg_integer()
  def lifetime_embed_tokens(user_id) when is_binary(user_id) do
    Repo.one(
      from(m in Meter, where: m.user_id == ^user_id, select: m.lifetime_embed_tokens),
      skip_tenant_check: true
    ) || 0
  end

  @doc """
  Monotonically increments the lifetime embed-token counter. Returns
  the new total. Uses a single upsert so concurrent embeds can't lose
  increments to a read-modify-write race.
  """
  @spec add_embed_tokens(Ecto.UUID.t(), non_neg_integer()) :: non_neg_integer()
  def add_embed_tokens(user_id, count)
      when is_binary(user_id) and is_integer(count) and count > 0 do
    now = DateTime.utc_now()

    {1, [%{lifetime_embed_tokens: total}]} =
      Repo.insert_all(
        Meter,
        [%{user_id: user_id, lifetime_embed_tokens: count, updated_at: now}],
        on_conflict: [inc: [lifetime_embed_tokens: count], set: [updated_at: now]],
        conflict_target: :user_id,
        returning: [:lifetime_embed_tokens],
        skip_tenant_check: true
      )

    total
  end

  def add_embed_tokens(user_id, 0) when is_binary(user_id), do: lifetime_embed_tokens(user_id)

  @doc """
  Gives back a reservation whose embed call failed: to the lifetime meter, and
  to the refilling bucket when the user has one (a NULL bucket, already full,
  stays NULL). Not clamped here: the next `bucket_take/4` clamps at capacity.
  """
  @spec release_embed_tokens(Ecto.UUID.t(), non_neg_integer()) :: :ok
  def release_embed_tokens(_user_id, 0), do: :ok

  def release_embed_tokens(user_id, count)
      when is_binary(user_id) and is_integer(count) and count > 0 do
    {_, _} =
      Repo.update_all(
        from(m in Meter, where: m.user_id == ^user_id),
        [inc: [lifetime_embed_tokens: -count, embed_bucket_tokens: count]],
        skip_tenant_check: true
      )

    :ok
  end

  # ── Refilling embed bucket (Free) ─────────────────────────────
  #
  # A token bucket in two `usage_meters` columns. Capacity is the plan's
  # `embed_token_bucket`; it refills continuously at one capacity per 365 days,
  # so there is no reset event and no cron. A NULL bucket is FULL: users who
  # never took (and every user that existed before the bucket) start with the
  # whole allowance. Same arithmetic as the retired `Engram.Usage.DailyCap`:
  # one statement refills, clamps and spends, and the conflict row lock
  # serializes concurrent takes, so two jobs can never spend the same tokens.

  @bucket_refill_seconds 31_536_000

  @doc "Seconds one full bucket takes to refill from empty (365 days)."
  def bucket_refill_seconds, do: @bucket_refill_seconds

  # Module attributes, not local strings: sobelow's SQL.Query check cannot
  # prove a variable passed to `Repo.query/2` is constant. Fully parameterized.
  #
  # $1 user_id, $2 tokens, $3 capacity, $4 now, $5 refill per second.
  # GREATEST(0, ...) guards a clock that moved backward (`now` is the calling
  # node's), and the stamp never moves backward either, so a skewed node can
  # neither mint nor destroy refill.
  @take_sql """
  INSERT INTO usage_meters AS m
    (user_id, embed_bucket_tokens, embed_bucket_at, lifetime_embed_tokens, updated_at)
  VALUES ($1::uuid, $3::float8 - $2::bigint, $4::timestamptz, $2::bigint, $4::timestamptz AT TIME ZONE 'UTC')
  ON CONFLICT (user_id) DO UPDATE SET
    embed_bucket_tokens = LEAST($3::float8,
      COALESCE(m.embed_bucket_tokens, $3::float8)
      + GREATEST(0, EXTRACT(EPOCH FROM ($4::timestamptz - COALESCE(m.embed_bucket_at, $4::timestamptz))))::float8
        * $5::float8) - $2::bigint,
    embed_bucket_at = GREATEST($4::timestamptz, COALESCE(m.embed_bucket_at, $4::timestamptz)),
    lifetime_embed_tokens = m.lifetime_embed_tokens + $2::bigint,
    updated_at = $4::timestamptz AT TIME ZONE 'UTC'
  WHERE LEAST($3::float8,
      COALESCE(m.embed_bucket_tokens, $3::float8)
      + GREATEST(0, EXTRACT(EPOCH FROM ($4::timestamptz - COALESCE(m.embed_bucket_at, $4::timestamptz))))::float8
        * $5::float8) >= $2::bigint
  RETURNING embed_bucket_tokens
  """

  @available_sql """
  SELECT LEAST($2::float8,
    COALESCE(embed_bucket_tokens, $2::float8)
    + GREATEST(0, EXTRACT(EPOCH FROM ($3::timestamptz - COALESCE(embed_bucket_at, $3::timestamptz))))::float8
      * $4::float8)
  FROM usage_meters WHERE user_id = $1::uuid
  """

  @doc """
  Takes `tokens` from the user's refilling bucket of `capacity`, or refuses
  without spending anything. A successful take also counts toward the lifetime
  meter (analytics reads it). `opts[:now]` is a test seam.
  """
  @spec bucket_take(Ecto.UUID.t(), pos_integer(), non_neg_integer(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, :bucket_empty}
  def bucket_take(user_id, tokens, capacity, opts \\ [])
      when is_binary(user_id) and is_integer(tokens) and tokens > 0 and is_integer(capacity) do
    if tokens > capacity do
      {:error, :bucket_empty}
    else
      args = [Ecto.UUID.dump!(user_id), tokens, capacity * 1.0, utc_now(opts), rate(capacity)]

      case Repo.query!(@take_sql, args) do
        %{rows: [[left]]} -> {:ok, trunc(max(left, 0.0))}
        %{rows: []} -> {:error, :bucket_empty}
      end
    end
  end

  @doc "Whole tokens in the bucket now, without spending any. No row is a full bucket."
  @spec bucket_available(Ecto.UUID.t(), non_neg_integer(), keyword()) :: non_neg_integer()
  def bucket_available(user_id, capacity, opts \\ [])
      when is_binary(user_id) and is_integer(capacity) do
    args = [Ecto.UUID.dump!(user_id), capacity * 1.0, utc_now(opts), rate(capacity)]

    case Repo.query!(@available_sql, args) do
      %{rows: [[n]]} -> trunc(max(n, 0.0))
      %{rows: []} -> capacity
    end
  end

  @doc """
  The bucket level from a stored `{tokens, at}` pair, in Elixir, for reports
  that already hold the row (`Engram.Insights.Snapshot`). Same arithmetic as
  the SQL above; a nil pair is a full bucket.
  """
  @spec bucket_level(float() | nil, DateTime.t() | nil, non_neg_integer(), DateTime.t()) ::
          non_neg_integer()
  def bucket_level(nil, _at, capacity, _now), do: capacity

  def bucket_level(tokens, at, capacity, %DateTime{} = now) do
    elapsed = max(0, DateTime.diff(now, at, :microsecond)) / 1_000_000
    trunc(max(0.0, min(capacity * 1.0, tokens + elapsed * rate(capacity))))
  end

  @doc "When a bucket holding `available` of `capacity` is full again; nil when it already is."
  @spec bucket_full_at(non_neg_integer(), non_neg_integer(), DateTime.t()) :: DateTime.t() | nil
  def bucket_full_at(available, capacity, %DateTime{} = now),
    do: bucket_ready_at(available, capacity, capacity, now)

  @doc """
  When a bucket of `capacity` holding `available` has paid for `need` in
  total, at its refill rate; nil when it already holds it, or never refills.
  NOT capped at the capacity: the queue spends as it refills, so a backlog
  bigger than the bucket drains past the date the bucket would be full.
  """
  @spec bucket_ready_at(non_neg_integer(), non_neg_integer(), non_neg_integer(), DateTime.t()) ::
          DateTime.t() | nil
  def bucket_ready_at(available, need, capacity, %DateTime{} = now) do
    if available >= need or capacity <= 0 do
      nil
    else
      seconds = div((need - available) * @bucket_refill_seconds + capacity - 1, capacity)
      DateTime.add(now, seconds, :second)
    end
  end

  defp rate(capacity), do: capacity / @bucket_refill_seconds

  defp utc_now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

  @doc """
  Estimates Voyage token count from raw byte size. English averages ~4 bytes
  per token; we round up so the cap is conservative (we never undercount
  against the user). Real `usage.total_tokens` from the Voyage response is a
  follow-up.
  """
  @spec estimate_tokens(binary() | non_neg_integer()) :: non_neg_integer()
  def estimate_tokens(content) when is_binary(content), do: estimate_tokens(byte_size(content))
  def estimate_tokens(bytes) when is_integer(bytes) and bytes >= 0, do: div(bytes + 3, 4)

  def estimate_tokens(_), do: 0

  # ── Notes counter (pricing v2 §G) ─────────────────────────────

  @doc "Returns the maintained live-note count for the user (0 if no row yet)."
  @spec notes_count(Ecto.UUID.t()) :: non_neg_integer()
  def notes_count(user_id) when is_binary(user_id) do
    Repo.one(
      from(m in Meter, where: m.user_id == ^user_id, select: m.notes_count),
      skip_tenant_check: true
    ) || 0
  end

  @doc """
  Adds `delta` to the user's live-note count, lazy-initialising the row. Use a
  positive `delta` when notes become live (insert/restore). Single upsert so
  concurrent writes can't lose increments to a read-modify-write race.
  """
  @spec inc_notes_count(Ecto.UUID.t(), pos_integer()) :: :ok
  def inc_notes_count(user_id, delta)
      when is_binary(user_id) and is_integer(delta) and delta > 0 do
    now = DateTime.utc_now()

    {_, _} =
      Repo.insert_all(
        Meter,
        [%{user_id: user_id, notes_count: delta, updated_at: now}],
        on_conflict: [inc: [notes_count: delta], set: [updated_at: now]],
        conflict_target: :user_id,
        skip_tenant_check: true
      )

    evict_note_counts(user_id)
  end

  @doc """
  Subtracts `delta` from the user's live-note count, clamped at zero so drift
  or a missing row can never produce a negative. Use when notes leave the live
  set (soft-delete, bulk hard-delete). No-op when no meter row exists.
  """
  @spec dec_notes_count(Ecto.UUID.t(), non_neg_integer()) :: :ok
  def dec_notes_count(_user_id, 0), do: :ok

  def dec_notes_count(user_id, delta)
      when is_binary(user_id) and is_integer(delta) and delta > 0 do
    now = DateTime.utc_now()

    {_, _} =
      from(m in Meter,
        where: m.user_id == ^user_id,
        update: [
          set: [
            notes_count: fragment("GREATEST(0, ? - ?)", m.notes_count, ^delta),
            updated_at: ^now
          ]
        ]
      )
      |> Repo.update_all([], skip_tenant_check: true)

    evict_note_counts(user_id)
  end

  # The cached counts (`:note_counts`) the bootstrap reads. The trigger's NOTIFY
  # evicts every node on commit; this makes the writing node coherent without
  # waiting for it. Engram.Cache.evict/2 itself waits for the commit.
  defp evict_note_counts(user_id), do: Engram.Cache.evict(:note_counts, user_id)

  @doc """
  Recomputes the live-note count from the notes table and upserts it. Repair
  primitive for reconciling drift; not on any hot path.

  Counts only `kind="note"` rows — explicit folder markers (`kind="folder"`)
  are structural metadata, not user-facing notes, and have a separate quota
  path. See `Engram.Notes.create_folder_marker/3`.
  """
  @spec recount_notes!(Ecto.UUID.t()) :: non_neg_integer()
  def recount_notes!(user_id) when is_binary(user_id) do
    # `notes` carries FORCE ROW LEVEL SECURITY. `skip_tenant_check: true`
    # silences only Engram's app-level guard and leaves `app.current_tenant`
    # unset, so the policy compares against NULL and filters every row.
    # Here that is worse than a wrong read: the 0 is UPSERT-ed over a correct
    # counter below, turning a silent read bug into persisted corruption.
    #
    # The Meter upsert that follows keeps `skip_tenant_check: true` — the
    # `usage_meters` table has no RLS policy (see rls_coverage_test's
    # no-RLS allowlist), so it is unaffected.
    {:ok, count} =
      Repo.with_tenant(user_id, fn ->
        Repo.one(
          from(n in Engram.Notes.Note,
            where:
              n.user_id == ^user_id and is_nil(n.deleted_at) and
                n.kind == "note",
            select: count(n.id)
          )
        ) || 0
      end)

    now = DateTime.utc_now()

    {_, _} =
      Repo.insert_all(
        Meter,
        [%{user_id: user_id, notes_count: count, updated_at: now}],
        on_conflict: [set: [notes_count: count, updated_at: now]],
        conflict_target: :user_id,
        skip_tenant_check: true
      )

    count
  end

  # ── Activity tracking (pricing v2 §C) ─────────────────────────

  @spec last_active_at(Ecto.UUID.t()) :: DateTime.t() | nil
  def last_active_at(user_id) when is_binary(user_id) do
    Repo.one(
      from(m in Meter, where: m.user_id == ^user_id, select: m.last_active_at),
      skip_tenant_check: true
    )
  end

  @doc """
  Debounced liveness stamp: writes `last_active_at` only when the stored value
  is stale by more than the activity debounce window, so a busy client
  does not hammer the meter row. A warm cache inside the window touches no DB
  at all.

  This is what tells `Engram.Workers.InactivityCleanup` who is actually using
  Engram — the sweep soft-deletes Free accounts whose `last_active_at` has
  aged past the window. It must therefore be called from EVERY transport a
  user can be "active" on, not just HTTP: `EngramWeb.Plugs.BumpActivity` for
  requests, `EngramWeb.ChannelGate` for `sync:`/`crdt:` joins. A plugin user
  who syncs daily over WebSocket and never touches REST would otherwise age
  into the sweep while in constant active use.
  """
  @spec touch_active(Ecto.UUID.t()) :: :ok
  def touch_active(user_id) when is_binary(user_id) do
    case Cache.get(:activity, user_id) do
      {:ok, %DateTime{} = ts} ->
        if stale?(ts), do: do_touch(user_id), else: :ok

      :miss ->
        last = last_active_at(user_id)

        if stale?(last) do
          do_touch(user_id)
        else
          Cache.put(:activity, user_id, last)
          :ok
        end
    end
  end

  defp do_touch(user_id) do
    now = DateTime.utc_now()
    :ok = bump_last_active(user_id)
    Cache.put(:activity, user_id, now)
    :ok
  end

  defp stale?(nil), do: true

  defp stale?(%DateTime{} = ts) do
    DateTime.diff(DateTime.utc_now(), ts, :second) > @debounce_seconds
  end

  @doc """
  Stamps `last_active_at = now()` for the user. Lazy-inits the row.
  Undebounced — callers go through `touch_active/1`, which owns the debounce.
  """
  @spec bump_last_active(Ecto.UUID.t()) :: :ok
  def bump_last_active(user_id) when is_binary(user_id) do
    now = DateTime.utc_now()

    {_, _} =
      Repo.insert_all(
        Meter,
        [%{user_id: user_id, last_active_at: now, updated_at: now}],
        on_conflict: [set: [last_active_at: now, updated_at: now]],
        conflict_target: :user_id,
        skip_tenant_check: true
      )

    :ok
  end
end
