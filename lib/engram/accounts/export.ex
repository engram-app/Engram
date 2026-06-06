defmodule Engram.Accounts.Export do
  @moduledoc """
  Account data export: request, list, mint download URL.

  - Free tier: 1 export per lifetime (configured via LimitKeys).
  - Paid tiers: 1 per 24h (configured via LimitKeys).
  - Size cap per tier (configured via LimitKeys).

  Worker streams Zstream → S3 multipart, per-vault, 10 GB max per part.
  """

  alias Engram.Accounts.Export.Schema
  alias Engram.Accounts.User
  alias Engram.Repo
  alias Engram.Workers.AccountExport

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
  end

  defp enqueue_worker(export) do
    %{"export_id" => export.id}
    |> AccountExport.new()
    |> Oban.insert()
  end

  # Task 9 fills these in.
  defp rate_limit_check(_user), do: :ok
  defp size_estimate_check(_user), do: :ok
end
