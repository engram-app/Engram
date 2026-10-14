defmodule Engram.Legal do
  @moduledoc """
  Canonical legal-document versions and the computed gate inputs.

  `required_floor/1` is the latest MATERIAL version whose effective_date has
  arrived (nil = effective immediately) — the version below which an acceptance
  is no longer binding. `current_version/1` is the latest published version (what
  the app renders / asks the user to accept), regardless of effective_date.

  These read the DB directly; callers on the hot path go through
  `Engram.Legal.VersionCache`, which memoizes them in :persistent_term.
  """
  import Ecto.Query
  alias Engram.Legal.TermsVersion
  alias Engram.Repo

  # Version ordering is lexicographic on the version string. This is load-bearing:
  # it only equals calendar ordering because versions are constrained to
  # YYYY-MM-DD by TermsVersion's validate_format. Keep that constraint.

  @urls %{
    "terms_of_service" => "https://engram.page/terms",
    "privacy_policy" => "https://engram.page/privacy"
  }

  @doc "Public page for a document."
  @spec url(String.t()) :: String.t()
  def url(document), do: Map.fetch!(@urls, document)

  @doc "Where a signed-in user reviews and accepts the current versions."
  @spec accept_url() :: String.t()
  def accept_url, do: "https://app.engram.page/onboard/agreement"

  @spec required_floor(document :: String.t(), today :: Date.t()) :: String.t() | nil
  def required_floor(document, today \\ Date.utc_today()) do
    from(v in TermsVersion,
      where: v.document == ^document and v.material == true,
      where: is_nil(v.effective_date) or v.effective_date <= ^today,
      order_by: [desc: v.version],
      limit: 1,
      select: v.version
    )
    |> Repo.one(skip_tenant_check: true)
  end

  @spec current_version(document :: String.t()) :: String.t() | nil
  def current_version(document) do
    from(v in TermsVersion,
      where: v.document == ^document,
      order_by: [desc: v.version],
      limit: 1,
      select: v.version
    )
    |> Repo.one(skip_tenant_check: true)
  end

  @spec hash_for(document :: String.t(), version :: String.t()) :: String.t() | nil
  def hash_for(document, version) do
    from(v in TermsVersion,
      where: v.document == ^document and v.version == ^version,
      select: v.content_hash
    )
    |> Repo.one(skip_tenant_check: true)
  end

  @doc "The full row for a version, or nil. Used for changelog/effective_date in the notice."
  @spec get(document :: String.t(), version :: String.t()) :: TermsVersion.t() | nil
  def get(document, version) do
    Repo.get_by(TermsVersion, [document: document, version: version], skip_tenant_check: true)
  end
end
