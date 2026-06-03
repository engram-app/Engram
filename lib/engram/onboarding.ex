defmodule Engram.Onboarding do
  @moduledoc """
  Onboarding context: TOS acceptance tracking and wizard-state computation.

  Wizard is fully disabled when `Application.get_env(:engram, :billing_enabled)`
  is false (self-host mode). In that mode `status/1` reports `next_step: :done`
  unconditionally and `RequireOnboarding` is a no-op.
  """

  alias Engram.Billing
  alias Engram.Legal
  alias Engram.Legal.VersionCache
  alias Engram.Onboarding.Agreement
  alias Engram.Onboarding.TermsCache
  alias Engram.Repo
  alias Engram.Vaults

  @terms_document "terms_of_service"
  @privacy_document "privacy_policy"

  # FTUX questionnaire tool catalog. Add new clients here in lockstep with
  # the frontend constants (see frontend/src/onboarding/questionnaire/tools.ts).
  # Renames are MIGRATIONS — old slugs in user rows won't be auto-rewritten.
  @valid_tools ~w(claude chatgpt web_only claude_code cursor continue_cline other_mcp)

  @doc """
  Returns the canonical list of valid tool slugs accepted by `set_profile/2`.
  """
  def valid_tools, do: @valid_tools

  @doc """
  Record that `user` accepted Terms of Service version `tos_version` (pinned by
  `tos_hash`) and Privacy Policy version `privacy_version` (pinned by
  `privacy_hash`). Both rows share the same `accepted_at`/ip/ua audit metadata.
  `meta` may carry `:ip_address` (string) and `:user_agent` (string).

  Returns `{:ok, %Agreement{}}` (the ToS row) when both inserts succeed, or
  `{:error, %Ecto.Changeset{}}` for the first row that fails.
  """
  def accept_terms(user, tos_version, tos_hash, privacy_version, privacy_hash, meta)
      when is_binary(tos_version) and is_binary(privacy_version) do
    accepted_at = DateTime.utc_now(:second)
    ip = Map.get(meta, :ip_address)
    ua = Map.get(meta, :user_agent)

    base = %{
      user_id: user.id,
      accepted_at: accepted_at,
      ip_address: ip,
      user_agent: ua
    }

    # Atomic: a ToS row without its paired Privacy row is an incomplete audit
    # record, so roll back the first insert if the second fails.
    result =
      Repo.transaction(fn ->
        with {:ok, tos_row} <-
               insert_agreement(
                 Map.merge(base, %{
                   document: @terms_document,
                   version: tos_version,
                   content_hash: tos_hash
                 })
               ),
             {:ok, _privacy_row} <-
               insert_agreement(
                 Map.merge(base, %{
                   document: @privacy_document,
                   version: privacy_version,
                   content_hash: privacy_hash
                 })
               ) do
          tos_row
        else
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    case result do
      {:ok, tos_row} ->
        TermsCache.put_accepted(user.id, @terms_document, tos_version)
        TermsCache.put_accepted(user.id, @privacy_document, privacy_version)
        {:ok, tos_row}

      other ->
        other
    end
  end

  @doc """
  Record that `user` accepted Terms of Service version `version` (no content
  hash, no Privacy row). Retained for the existing controller/tests until the
  controller is migrated to the 6-arity form. Delegates to `insert_agreement/1`.
  """
  def accept_terms(user, version, meta) when is_binary(version) do
    insert_agreement(%{
      user_id: user.id,
      document: @terms_document,
      version: version,
      accepted_at: DateTime.utc_now(:second),
      ip_address: Map.get(meta, :ip_address),
      user_agent: Map.get(meta, :user_agent)
    })
  end

  # Upsert on (user_id, document, version) so re-accepts of the same version
  # refresh the audit fields instead of inserting duplicate rows. Unique
  # index `user_agreements_user_document_version_unique` enforces this at DB.
  defp insert_agreement(attrs) do
    %Agreement{}
    |> Agreement.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:accepted_at, :ip_address, :user_agent, :content_hash]},
      conflict_target: [:user_id, :document, :version],
      returning: true,
      skip_tenant_check: true
    )
  end

  @doc """
  Compute the onboarding state for a user. Returns a map with:

    * `:enabled` — true when billing (and therefore the wizard) is active
    * `:terms_ok` — latest accepted ToS version satisfies the computed floor
    * `:subscription_ok` — user has trialing/active/past_due subscription
    * `:current_tos_version` — latest published ToS version (from `terms_versions`)
    * `:current_privacy_version` — latest published Privacy version
    * `:terms_notice` — metadata for the newest published ToS version the user
      has not yet accepted (version/effective_date/material/changelog/accept_url),
      or `nil` when the user is already on the current version
    * `:next_step` — one of `:agreement | :billing | :done`

  The gate is computed from the `terms_versions` table via
  `Engram.Legal.VersionCache`: `terms_ok` compares the user's latest accepted
  version against the required floor (latest MATERIAL version effective now).

  `:terms_notice` is independent of `:terms_ok`: it carries the pending version's
  metadata whenever a newer published version exists unaccepted, and is the same
  payload the client renders both as the non-blocking notice (while `terms_ok`
  is still true, before the version's `effective_date`) and as the accept prompt
  once the version is effective and `terms_ok` has flipped false.

  When `billing_enabled` is false (self-host), returns `{enabled: false,
  next_step: :done}` immediately so callers can skip all gates.
  """
  def status(user) do
    if Application.get_env(:engram, :billing_enabled, false) do
      floor = VersionCache.required_floor(@terms_document)
      current_tos = VersionCache.current_version(@terms_document)
      current_privacy = VersionCache.current_version(@privacy_document)

      accepted_tos = accepted_version(user, @terms_document)
      terms_ok = accepted_satisfies?(accepted_tos, floor)
      subscription_ok = Billing.active?(user)
      profile = current_profile(user)
      profile_complete = profile_complete?(profile)
      has_vault = Vaults.has_vault?(user)
      next = next_step(terms_ok, subscription_ok, profile_complete, profile, has_vault)

      %{
        enabled: true,
        terms_ok: terms_ok,
        subscription_ok: subscription_ok,
        profile_complete: profile_complete,
        profile: profile,
        has_vault: has_vault,
        current_tos_version: current_tos,
        current_privacy_version: current_privacy,
        terms_notice: notice(@terms_document, current_tos, accepted_tos),
        next_step: next
      }
    else
      %{enabled: false, next_step: :done}
    end
  end

  @doc """
  Store the FTUX questionnaire answers on `user.onboarding_profile`. Validates
  `uses_obsidian` is a boolean, `tools` is non-empty, and every tool slug
  belongs to `valid_tools/0`. Stamps `completed_at` so `status/1` flips
  `profile_complete: true` and (when terms+subscription are ok) `next_step: :done`.

  Returns `{:ok, %User{}}` or `{:error, atom}` where atom is one of
  `:invalid_uses_obsidian | :empty_tools | :invalid_tool`.
  """
  def set_profile(user, %{uses_obsidian: uses_obsidian, tools: tools}) when is_list(tools) do
    cond do
      not is_boolean(uses_obsidian) ->
        {:error, :invalid_uses_obsidian}

      tools == [] ->
        {:error, :empty_tools}

      Enum.any?(tools, &(&1 not in @valid_tools)) ->
        {:error, :invalid_tool}

      true ->
        profile = %{
          "uses_obsidian" => uses_obsidian,
          "tools" => tools,
          "completed_at" => DateTime.utc_now(:second) |> DateTime.to_iso8601()
        }

        user
        |> Ecto.Changeset.change(onboarding_profile: profile)
        |> Repo.update(skip_tenant_check: true)
    end
  end

  # Re-read the column rather than trusting the caller's struct — callers that
  # just ran `set_profile/2` and then `status/1` would otherwise see a stale
  # `nil` and the gate would stick on `:profile` even after a successful save.
  defp current_profile(user) do
    import Ecto.Query

    from(u in Engram.Accounts.User,
      where: u.id == ^user.id,
      select: u.onboarding_profile
    )
    |> Repo.one(skip_tenant_check: true)
  end

  defp profile_complete?(%{"completed_at" => ts}) when is_binary(ts), do: true
  defp profile_complete?(_), do: false

  # Cache-first read of the user's latest accepted version for a document.
  defp accepted_version(user, document) do
    case TermsCache.accepted_version(user.id, document) do
      nil ->
        v = query_accepted_version(user, document)
        if v, do: TermsCache.put_accepted(user.id, document, v)
        v

      cached ->
        cached
    end
  end

  defp accepted_satisfies?(nil, _floor), do: false
  defp accepted_satisfies?(_accepted, nil), do: true
  defp accepted_satisfies?(accepted, floor), do: accepted >= floor

  # A notice is due when there is a current version the user hasn't accepted yet.
  defp notice(_document, nil, _accepted), do: nil

  defp notice(document, current, accepted)
       when is_nil(accepted) or current > accepted do
    case Legal.get(document, current) do
      nil ->
        nil

      row ->
        %{
          document: document,
          version: row.version,
          effective_date: row.effective_date,
          material: row.material,
          changelog: row.changelog,
          accept_url: "https://app.engram.page/onboard/agreement"
        }
    end
  end

  defp notice(_document, _current, _accepted), do: nil

  defp query_accepted_version(user, document) do
    import Ecto.Query

    from(a in Agreement,
      where: a.user_id == ^user.id and a.document == ^document,
      order_by: [desc: a.accepted_at],
      limit: 1,
      select: a.version
    )
    |> Repo.one(skip_tenant_check: true)
  end

  defp next_step(false, _, _, _, _), do: :agreement
  defp next_step(true, false, _, _, _), do: :billing
  defp next_step(true, true, false, _, _), do: :profile

  defp next_step(true, true, true, profile, has_vault) do
    # uses_obsidian=true short-circuits past the vault gate: the plugin's
    # OAuth flow creates the vault on first sign-in, so we don't block the
    # dashboard waiting for it. Fresh-path users MUST land on /onboard/vault
    # to name + create a vault (otherwise they hit an empty dashboard with
    # no notes).
    cond do
      profile_uses_obsidian?(profile) -> :done
      has_vault -> :done
      true -> :vault
    end
  end

  defp profile_uses_obsidian?(%{"uses_obsidian" => true}), do: true
  defp profile_uses_obsidian?(_), do: false
end
