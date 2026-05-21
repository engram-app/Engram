defmodule Engram.Billing.FounderCodes do
  @moduledoc """
  Pricing v2 §F — one-time-per-Clerk-identity redemption guard for promotional
  codes that we don't want chained across churn-and-resubscribe.

  Two codes are tracked:

    - `:founder` — 30%-off-12-months waitlist code. Stamps
      `users.founder_code_redeemed_at`.
    - `:og_grandfather` — locks an OG waitlist signup to v1 prices ($5/$10).
      Stamps `users.og_grandfather_redeemed_at`.

  A returning user (churned + resubscribed) sees v2 prices, not the founder
  rate — explicit and predictable per the work-order acceptance criteria.

  Multi-account farming via email aliases is closed by §A's normalizer; the
  per-user flag here closes the second half (alias-replay against the SAME
  Clerk identity).
  """

  alias Engram.Accounts.User
  alias Engram.Repo

  @type code :: :founder | :og_grandfather
  @type error_reason :: :already_redeemed | :unknown_code

  @doc """
  Redeems a one-time promotional code for the user.

  Returns `{:ok, %User{}}` with the updated stamp on first redemption,
  `{:error, :already_redeemed}` on any subsequent attempt, or
  `{:error, :unknown_code}` for an unrecognized code atom.

  Stamp is set via `Repo.update_all` with a `WHERE field IS NULL` guard so
  two concurrent redemption attempts can't both succeed — exactly one row
  updates and the other returns `:already_redeemed`.
  """
  @spec redeem(User.t(), code()) :: {:ok, User.t()} | {:error, error_reason()}
  def redeem(%User{} = user, code) when code in [:founder, :og_grandfather] do
    field = stamp_field(code)
    now = DateTime.utc_now()

    {count, _} =
      Repo.update_all(
        guard_query(user.id, field),
        [set: [{field, now}]],
        skip_tenant_check: true
      )

    case count do
      1 -> {:ok, %{user | field => now}}
      0 -> {:error, :already_redeemed}
    end
  end

  def redeem(%User{}, _), do: {:error, :unknown_code}

  @doc """
  Returns true if the user has already redeemed the given code.
  """
  @spec redeemed?(User.t(), code()) :: boolean()
  def redeemed?(%User{founder_code_redeemed_at: %DateTime{}}, :founder), do: true
  def redeemed?(%User{og_grandfather_redeemed_at: %DateTime{}}, :og_grandfather), do: true
  def redeemed?(%User{}, code) when code in [:founder, :og_grandfather], do: false

  defp stamp_field(:founder), do: :founder_code_redeemed_at
  defp stamp_field(:og_grandfather), do: :og_grandfather_redeemed_at

  defp guard_query(user_id, field) do
    import Ecto.Query
    from u in User, where: u.id == ^user_id and is_nil(field(u, ^field))
  end
end
