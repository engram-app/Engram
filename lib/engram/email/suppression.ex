defmodule Engram.Email.Suppression do
  @moduledoc """
  Suppression list for engram-originated email. An address lands here when
  Resend reports a bounce or spam complaint; `Engram.Mailer` consults
  `suppressed?/1` before sending and skips suppressed addresses. Addresses are
  stored normalized to lowercase.
  """
  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias Engram.Repo

  schema "email_suppressions" do
    field :email, :string
    field :reason, Ecto.Enum, values: [:bounced, :complained]

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}
  @type reason :: :bounced | :complained

  @doc "Record `email` as suppressed for `reason` (idempotent on the address)."
  @spec suppress(String.t(), reason()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def suppress(email, reason) do
    %__MODULE__{}
    |> changeset(%{email: email, reason: reason})
    |> Repo.insert(on_conflict: {:replace, [:reason]}, conflict_target: :email)
  end

  @doc "True if `email` is on the suppression list (case-insensitive)."
  @spec suppressed?(String.t()) :: boolean()
  def suppressed?(email) when is_binary(email) do
    normalized = String.downcase(email)
    Repo.exists?(from(s in __MODULE__, where: s.email == ^normalized))
  end

  defp changeset(suppression, attrs) do
    suppression
    |> cast(attrs, [:email, :reason])
    |> update_change(:email, &String.downcase/1)
    |> validate_required([:email, :reason])
    |> unique_constraint(:email)
    |> check_constraint(:reason, name: :reason_must_be_valid)
  end
end
