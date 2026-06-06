defmodule Engram.Accounts.Export do
  @moduledoc """
  Account data export: request, list, mint download URL.

  - Free tier: 1 export per lifetime (configured via LimitKeys).
  - Paid tiers: 1 per 24h (configured via LimitKeys).
  - Size cap per tier (configured via LimitKeys).

  Worker streams Zstream → S3 multipart, per-vault, 10 GB max per part.
  """

  import Ecto.Query

  alias Engram.Accounts.Export.Schema
  alias Engram.Accounts.User
  alias Engram.Billing
  alias Engram.Repo
  alias Engram.Workers.AccountExport

  # Rough per-note overhead to size-estimate the zipped JSON manifest
  # without summing the actual encrypted ciphertext lengths. 4 KB/note is
  # generous enough to cover most markdown bodies plus frontmatter; the
  # streaming worker re-checks the real size against the cap as it writes.
  @note_overhead_bytes 4_096

  @spec request(User.t()) :: {:ok, Schema.t()} | {:error, atom()}
  def request(%User{} = user) do
    with :ok <- rate_limit_check(user),
         :ok <- size_estimate_check(user),
         {:ok, export} <- insert_pending(user),
         {:ok, _job} <- enqueue_worker(export) do
      {:ok, export}
    end
  end

  defp insert_pending(user) do
    %Schema{}
    |> Schema.changeset(%{user_id: user.id, status: :pending, reason: :user_request})
    |> Repo.insert(skip_tenant_check: true)
    |> case do
      {:ok, export} ->
        {:ok, export}

      {:error, %Ecto.Changeset{errors: errors} = cs} ->
        if unique_constraint_violation?(errors),
          do: {:error, :already_running},
          else: {:error, cs}
    end
  end

  defp unique_constraint_violation?(errors) do
    Enum.any?(errors, fn {_field, {_msg, opts}} ->
      Keyword.get(opts, :constraint) == :unique
    end)
  end

  defp enqueue_worker(export) do
    %{"export_id" => export.id}
    |> AccountExport.new()
    |> Oban.insert()
  end

  # ── Rate limiting ────────────────────────────────────────────────
  #
  # Two mutually exclusive caps are configured in LimitKeys:
  #   - account_exports_lifetime   (free: 1, paid: nil)
  #   - account_export_rate_per_24h (free: nil, paid: 1)
  #
  # Failed exports never burn quota — only :ready and :expired count as
  # "spent". In-flight (:pending / :running) rows are excluded from the
  # 24h window too; the unique partial index handles concurrent requests
  # separately so an in-flight retry surfaces as :already_running rather
  # than :rate_exceeded.

  defp rate_limit_check(%User{} = user) do
    cond do
      lifetime_cap = cap_for(user,:account_exports_lifetime) ->
        if Repo.aggregate(used_lifetime_q(user), :count) >= lifetime_cap,
          do: {:error, :lifetime_exceeded},
          else: :ok

      per_24h_cap = cap_for(user,:account_export_rate_per_24h) ->
        if Repo.aggregate(recent_24h_q(user), :count) >= per_24h_cap,
          do: {:error, :rate_exceeded},
          else: :ok

      true ->
        :ok
    end
  end

  defp used_lifetime_q(user) do
    from(e in Schema,
      where: e.user_id == ^user.id and e.status in [:ready, :expired]
    )
  end

  defp recent_24h_q(user) do
    cutoff = DateTime.utc_now() |> DateTime.add(-86_400, :second)

    from(e in Schema,
      where:
        e.user_id == ^user.id and
          e.inserted_at >= ^cutoff and
          e.status in [:ready, :expired]
    )
  end

  # ── Size estimation ──────────────────────────────────────────────

  defp size_estimate_check(%User{} = user) do
    case cap_for(user,:account_export_max_bytes) do
      nil ->
        :ok

      cap when is_integer(cap) ->
        if estimate_bytes(user) <= cap,
          do: :ok,
          else: {:error, :too_large}
    end
  end

  defp estimate_bytes(user) do
    attachment_bytes(user) + note_overhead(user)
  end

  defp attachment_bytes(user) do
    Repo.one(
      from(a in "attachments",
        where: a.user_id == ^user.id,
        select: coalesce(sum(a.size_bytes), 0)
      ),
      skip_tenant_check: true
    )
    |> to_integer()
  end

  defp to_integer(nil), do: 0
  defp to_integer(n) when is_integer(n), do: n
  defp to_integer(%Decimal{} = d), do: Decimal.to_integer(d)

  defp note_overhead(user) do
    count =
      Repo.one(
        from(n in "notes",
          where: n.user_id == ^user.id,
          select: count(n.id)
        ),
        skip_tenant_check: true
      ) || 0

    count * @note_overhead_bytes
  end

  # `effective_limit/2` returns `:unlimited` when limits enforcement is
  # disabled (selfhost) and the catalog default itself can be `nil` for
  # "no cap on this tier"; normalize both to `nil` so the cond/case
  # arms above can treat "no cap" uniformly.
  defp cap_for(user,key) do
    case Billing.effective_limit(user, key) do
      :unlimited -> nil
      v -> v
    end
  end
end
