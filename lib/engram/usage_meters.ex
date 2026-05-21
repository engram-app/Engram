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

    @primary_key {:user_id, :id, autogenerate: false}
    schema "usage_meters" do
      field :lifetime_embed_tokens, :integer, default: 0
      field :updated_at, :utc_datetime_usec
    end
  end

  @spec lifetime_embed_tokens(integer()) :: non_neg_integer()
  def lifetime_embed_tokens(user_id) when is_integer(user_id) do
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
      when is_integer(user_id) and is_integer(count) and count > 0 do
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
end
