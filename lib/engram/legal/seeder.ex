defmodule Engram.Legal.Seeder do
  @moduledoc """
  Seeds + verifies `terms_versions` from the vendored
  `priv/legal/legal-manifest.json` (the #318 single source of truth: same bytes
  the frontend vendors). The manifest carries version→hash only; the
  effective_date/material/changelog for known versions live in @version_meta.

  `seed/0` upserts a row per manifest entry. `verify/0` raises if any DB row's
  hash diverges from the manifest (fail loud rather than silently 409 every
  signup). Both run at boot (Application), then VersionCache is invalidated.
  """
  import Ecto.Query
  alias Engram.Legal.TermsVersion
  alias Engram.Repo

  # document => version => %{material, effective_date, changelog}
  #
  # IMPORTANT: every version present in the vendored manifest MUST have an entry
  # here, or `meta!/2` raises at boot (fail-loud). So a legal bump is a TWO-file
  # change: add the version→hash to priv/legal/legal-manifest.json AND its
  # material/effective_date/changelog here. (P5 will automate this cross-repo.)
  @version_meta %{
    "terms_of_service" => %{
      "2026-05-19" => %{material: true, effective_date: nil, changelog: "Initial version."}
    },
    "privacy_policy" => %{
      "2026-06-20" => %{
        material: true,
        effective_date: nil,
        changelog:
          "Accuracy fixes: scope clarified to cover the app (not just the marketing site); Grafana Cloud added to sub-processors."
      }
    }
  }

  @spec seed() :: :ok
  def seed do
    for {document, versions} <- manifest(),
        {version, hash} <- versions do
      meta = meta!(document, version)

      %TermsVersion{}
      |> TermsVersion.changeset(%{
        document: document,
        version: version,
        content_hash: hash,
        material: meta.material,
        effective_date: meta.effective_date,
        changelog: meta.changelog
      })
      |> Repo.insert!(
        on_conflict: {:replace, [:content_hash, :material, :effective_date, :changelog]},
        conflict_target: [:document, :version],
        skip_tenant_check: true
      )
    end

    :ok
  end

  @spec verify() :: :ok
  def verify do
    for {document, versions} <- manifest(), {version, hash} <- versions do
      row =
        Repo.one(
          from(v in TermsVersion,
            where: v.document == ^document and v.version == ^version,
            select: v.content_hash
          ),
          skip_tenant_check: true
        )

      if row != hash do
        raise "legal: hash drift for #{document} #{version} " <>
                "(manifest=#{hash} db=#{inspect(row)}) — terms_versions out of sync with manifest"
      end
    end

    :ok
  end

  defp manifest do
    path = Application.app_dir(:engram, "priv/legal/legal-manifest.json")
    path |> File.read!() |> Jason.decode!()
  end

  defp meta!(document, version) do
    get_in(@version_meta, [document, version]) ||
      raise "legal: no seed meta (material/effective_date/changelog) for #{document} #{version}"
  end
end
