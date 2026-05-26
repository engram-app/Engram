defmodule Engram.Email.Recipient do
  @moduledoc """
  A validated email recipient sourced from outside the `users` table (e.g. the
  OG-waitlist audit CSV). Constructing one validates the address, giving a
  single boundary where untrusted recipient data is checked before it reaches a
  template. Contrast `%Engram.Accounts.User{}`, used for lifecycle mail.
  """

  @enforce_keys [:email, :name]
  defstruct [:email, :name]

  @type t :: %__MODULE__{email: String.t(), name: String.t()}

  # Deliberately loose: an operator-facing guard against malformed CSV rows,
  # not RFC 5322 validation. Must have a single @ with non-empty, dot-bearing
  # local/domain parts.
  @email ~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/

  @doc "Build a recipient from an email + name, validating the address."
  @spec new(term(), term()) :: {:ok, t()} | {:error, :invalid_email}
  def new(email, name) do
    email = email |> to_string() |> String.trim()
    name = name |> to_string() |> String.trim()

    if Regex.match?(@email, email) do
      {:ok, %__MODULE__{email: email, name: name}}
    else
      {:error, :invalid_email}
    end
  end
end
