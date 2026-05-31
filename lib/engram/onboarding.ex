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
  alias Engram.Onboarding.Action
  alias Engram.Onboarding.Agreement
  alias Engram.Onboarding.TermsCache
  alias Engram.Repo

  @terms_document "terms_of_service"
  @privacy_document "privacy_policy"

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
      next = next_step(terms_ok, subscription_ok)

      %{
        enabled: true,
        terms_ok: terms_ok,
        subscription_ok: subscription_ok,
        current_tos_version: current_tos,
        current_privacy_version: current_privacy,
        terms_notice: notice(@terms_document, current_tos, accepted_tos),
        next_step: next
      }
    else
      %{enabled: false, next_step: :done}
    end
  end

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

  defp next_step(false, _), do: :agreement
  defp next_step(true, false), do: :billing
  defp next_step(true, true), do: :done

  @doc """
  Record an onboarding milestone for `user_id`. Idempotent — re-recording the
  same action returns `:ok` with no extra row. Returns `{:error, changeset}`
  only on enum/validation failure.
  """
  def record_action(user_id, action) when is_atom(action) do
    record_action(user_id, Atom.to_string(action))
  end

  def record_action(user_id, action) when is_integer(user_id) and is_binary(action) do
    %Action{}
    |> Action.changeset(%{user_id: user_id, action: action})
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:user_id, :action],
      skip_tenant_check: true
    )
    |> case do
      {:ok, _} -> :ok
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
    end
  end

  @doc """
  Return the set of onboarding actions recorded for `user_id` as a list of
  string action names. Empty list for unknown user.
  """
  def list_actions(user_id) when is_integer(user_id) do
    import Ecto.Query

    from(a in Action, where: a.user_id == ^user_id, select: a.action)
    |> Repo.all(skip_tenant_check: true)
  end
end
