defmodule Engram.UsageMeters do
  @moduledoc """
  Per-user usage counters that drive pricing-v2 abuse defenses.

  Lifetime embed-token counter (§B): monotonic — never decremented on note
  delete so re-upload cycles can't reset the Free quota.

  Lazy-initialized: rows are inserted on first write via `add_embed_tokens/2`.
  Reads return zero for users without a row yet.
  """

  import Ecto.Query
  alias Engram.Repo

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
      field :last_active_at, :utc_datetime_usec
      field :active_conversation_started_at, :utc_datetime_usec
      field :active_conversation_query_count, :integer, default: 0
      field :conversations_today, :integer, default: 0
      field :conversations_day_key, :date
      field :queries_today, :integer, default: 0
      field :queries_day_key, :date
      field :updated_at, :utc_datetime_usec
    end
  end

  @spec lifetime_embed_tokens(integer()) :: non_neg_integer()
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
  @spec add_embed_tokens(integer(), non_neg_integer()) :: non_neg_integer()
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

  def add_embed_tokens(_user_id, 0), do: lifetime_embed_tokens(0)

  @doc """
  Estimates Voyage token count from raw byte size. English averages ~4 bytes
  per token; we round up so the cap is conservative (we never undercount
  against the user). Real `usage.total_tokens` from the Voyage response is a
  follow-up.
  """
  @spec estimate_tokens(binary()) :: non_neg_integer()
  def estimate_tokens(content) when is_binary(content) do
    div(byte_size(content) + 3, 4)
  end

  def estimate_tokens(_), do: 0

  # ── Notes counter (pricing v2 §G) ─────────────────────────────

  @doc "Returns the maintained live-note count for the user (0 if no row yet)."
  @spec notes_count(integer()) :: non_neg_integer()
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
  @spec inc_notes_count(integer(), pos_integer()) :: :ok
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

    :ok
  end

  @doc """
  Subtracts `delta` from the user's live-note count, clamped at zero so drift
  or a missing row can never produce a negative. Use when notes leave the live
  set (soft-delete, bulk hard-delete). No-op when no meter row exists.
  """
  @spec dec_notes_count(integer(), non_neg_integer()) :: :ok
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

    :ok
  end

  @doc """
  Recomputes the live-note count from the notes table and upserts it. Repair
  primitive for reconciling drift; not on any hot path.

  Counts only `kind="note"` rows — explicit folder markers (`kind="folder"`)
  are structural metadata, not user-facing notes, and have a separate quota
  path. See `Engram.Notes.create_folder_marker/3`.
  """
  @spec recount_notes!(integer()) :: non_neg_integer()
  def recount_notes!(user_id) when is_binary(user_id) do
    count =
      Repo.one(
        from(n in Engram.Notes.Note,
          where:
            n.user_id == ^user_id and is_nil(n.deleted_at) and
              n.kind == "note",
          select: count(n.id)
        ),
        skip_tenant_check: true
      ) || 0

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

  @spec last_active_at(integer()) :: DateTime.t() | nil
  def last_active_at(user_id) when is_binary(user_id) do
    Repo.one(
      from(m in Meter, where: m.user_id == ^user_id, select: m.last_active_at),
      skip_tenant_check: true
    )
  end

  @doc """
  Stamps `last_active_at = now()` for the user. Lazy-inits the row.
  Called from the auth pipeline plug (debounced to once per hour).
  """
  @spec bump_last_active(integer()) :: :ok
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
