defmodule Engram.Onboarding do
  @moduledoc """
  Onboarding context: TOS acceptance tracking and wizard-state computation.

  Wizard is fully disabled when `Application.get_env(:engram, :billing_enabled)`
  is false (self-host mode). In that mode `status/1` reports `next_step: :done`
  unconditionally and `RequireOnboarding` is a no-op.
  """

  alias Engram.Billing
  alias Engram.Onboarding.Agreement
  alias Engram.Repo

  @terms_document "terms_of_service"

  @doc """
  Record that `user` accepted document version `version`. `meta` may carry
  `:ip_address` (string) and `:user_agent` (string) for audit purposes.
  Returns `{:ok, %Agreement{}}` or `{:error, %Ecto.Changeset{}}`.
  """
  def accept_terms(user, version, meta) when is_binary(version) do
    attrs = %{
      user_id: user.id,
      document: @terms_document,
      version: version,
      accepted_at: DateTime.utc_now(:second),
      ip_address: Map.get(meta, :ip_address),
      user_agent: Map.get(meta, :user_agent)
    }

    # Upsert on (user_id, document, version) so re-accepts of the same version
    # refresh the audit fields instead of inserting duplicate rows. Unique
    # index `user_agreements_user_document_version_unique` enforces this at DB.
    %Agreement{}
    |> Agreement.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:accepted_at, :ip_address, :user_agent]},
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
      terms_ok = terms_accepted?(user, current_version)
      subscription_ok = Billing.active?(user)
      next = next_step(terms_ok, subscription_ok)

      %{
        enabled: true,
        terms_ok: terms_ok,
        subscription_ok: subscription_ok,
        current_tos_version: current_version,
        next_step: next
      }
    else
      %{enabled: false, next_step: :done}
    end
  end

  defp terms_accepted?(user, current_version) do
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
      accepted -> accepted >= current_version
    end
  end

  defp next_step(false, _), do: :agreement
  defp next_step(true, false), do: :billing
  defp next_step(true, true), do: :done
end
