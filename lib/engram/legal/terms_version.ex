defmodule Engram.Legal.TermsVersion do
  @moduledoc """
  A canonical legal-document version. Global (non-tenant). Rows are immutable
  once published — a correction is a new version. See `Engram.Legal`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @documents ~w(terms_of_service privacy_policy)

  schema "terms_versions" do
    field :document, :string
    field :version, :string
    field :content_hash, :string
    field :material, :boolean, default: true
    field :effective_date, :date
    field :changelog, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(version, attrs) do
    version
    |> cast(attrs, [:document, :version, :content_hash, :material, :effective_date, :changelog])
    |> validate_required([:document, :version, :content_hash])
    |> validate_inclusion(:document, @documents)
    |> validate_format(:version, ~r/^\d{4}-\d{2}-\d{2}$/)
    |> unique_constraint([:document, :version])
  end
end
