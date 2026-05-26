defmodule Engram.Onboarding do
  @moduledoc """
  Onboarding context: TOS acceptance tracking and wizard-state computation.

  Wizard is fully disabled when `Application.get_env(:engram, :billing_enabled)`
  is false (self-host mode). In that mode `status/1` reports `next_step: :done`
  unconditionally and `RequireOnboarding` is a no-op.
  """

  alias Engram.Billing
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
    * `:terms_ok` — current TOS version accepted
    * `:subscription_ok` — user has trialing/active/past_due subscription
    * `:current_tos_version` — string from config
    * `:next_step` — one of `:agreement | :billing | :done`

  When `billing_enabled` is false (self-host), returns `{enabled: false,
  next_step: :done}` immediately so callers can skip all gates.
  """
  def status(user) do
    if Application.get_env(:engram, :billing_enabled, false) do
      current_version = Application.get_env(:engram, :current_tos_version)
      min_required = Application.get_env(:engram, :min_required_tos_version)
      terms_ok = terms_accepted?(user, min_required)
      subscription_ok = Billing.active?(user)
      next = next_step(terms_ok, subscription_ok)

      %{
        enabled: true,
        terms_ok: terms_ok,
        subscription_ok: subscription_ok,
        current_tos_version: current_version,
        current_privacy_version: Application.get_env(:engram, :current_privacy_version),
        next_step: next
      }
    else
      %{enabled: false, next_step: :done}
    end
  end

  # Gate on `min_required_tos_version`: a bump to `current_tos_version` alone
  # (minor edit) must NOT force re-accept — only a `min_required` bump does.
  defp terms_accepted?(user, min_required) do
    if TermsCache.accepted?(user.id, min_required) do
      true
    else
      accepted = query_terms_accepted?(user, min_required)
      if accepted, do: TermsCache.mark_accepted(user.id, min_required)
      accepted
    end
  end

  defp query_terms_accepted?(user, min_required) do
    import Ecto.Query

    latest =
      from(a in Agreement,
        where: a.user_id == ^user.id and a.document == ^@terms_document,
        order_by: [desc: a.accepted_at],
        limit: 1,
        select: a.version
      )
      |> Repo.one(skip_tenant_check: true)

    case latest do
      nil -> false
      accepted -> accepted >= min_required
    end
  end

  defp next_step(false, _), do: :agreement
  defp next_step(true, false), do: :billing
  defp next_step(true, true), do: :done
end
