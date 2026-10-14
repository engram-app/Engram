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
  # material/effective_date/changelog here.
  #
  # Users are told automatically (`Engram.Workers.LegalNoticeDispatch`): a
  # version with a FUTURE effective_date emails everyone and shows the in-app
  # notice until that date. `effective_date: nil` means effective at once and
  # silent, which is for wording fixes only. Changing an announced version's
  # effective_date or material sends the notice again. A material change after a
  # document's first version needs an effective_date 30+ days after its
  # version date (ToS §13); `notice_violations/0` enforces it in CI.
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
      },
      # Notice-only: legitimate-interest analytics needs notice, not consent.
      # Notice-only, but the 30-day notice ToS §13 promises still runs:
      # PostHogPersonSync sends nothing before this effective_date.
      "2026-10-12" => %{
        material: false,
        effective_date: ~D[2026-11-11],
        changelog:
          "App analytics now linked to your account (email, plan, usage counts). The content of your notes is never sent."
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
        on_conflict: upsert(),
        conflict_target: [:document, :version],
        skip_tenant_check: true
      )
    end

    :ok
  end

  # Replace the meta. The sent stamps survive a reboot, but a changed date or
  # materiality clears them: the email already sent said the wrong thing, so
  # `LegalNoticeDispatch` tells users again. SET reads the OLD row's columns.
  defp upsert do
    from(v in TermsVersion,
      update: [
        set: [
          content_hash: fragment("EXCLUDED.content_hash"),
          material: fragment("EXCLUDED.material"),
          effective_date: fragment("EXCLUDED.effective_date"),
          changelog: fragment("EXCLUDED.changelog"),
          notified_at:
            fragment(
              "CASE WHEN (?, ?) IS DISTINCT FROM (EXCLUDED.effective_date, EXCLUDED.material) THEN NULL ELSE ? END",
              v.effective_date,
              v.material,
              v.notified_at
            ),
          reminded_at:
            fragment(
              "CASE WHEN (?, ?) IS DISTINCT FROM (EXCLUDED.effective_date, EXCLUDED.material) THEN NULL ELSE ? END",
              v.effective_date,
              v.material,
              v.reminded_at
            )
        ]
      ]
    )
  end

  @notice_days 30

  @doc "Material versions that give less than #{@notice_days} days' notice. Must be []."
  @spec notice_violations(map()) :: [{String.t(), String.t()}]
  def notice_violations(meta \\ @version_meta) do
    for {document, versions} <- Enum.sort(meta),
        # The first version per document is the publish-day baseline.
        {version, %{material: true} = m} <- versions |> Enum.sort() |> Enum.drop(1),
        not gives_notice?(version, m.effective_date),
        do: {document, version}
  end

  defp gives_notice?(_version, nil), do: false

  defp gives_notice?(version, effective_date),
    do: Date.diff(effective_date, Date.from_iso8601!(version)) >= @notice_days

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
