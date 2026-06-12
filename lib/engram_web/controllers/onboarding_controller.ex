defmodule EngramWeb.OnboardingController do
  use EngramWeb, :controller

  alias Engram.Legal.VersionCache
  alias Engram.Onboarding
  alias EngramWeb.RequestMeta

  def status(conn, _params) do
    user = conn.assigns.current_user

    payload =
      Onboarding.status(user)
      |> Map.update!(:next_step, &Atom.to_string/1)
      |> Map.update!(:steps, fn steps -> Enum.map(steps, &Atom.to_string/1) end)
      |> reject_nil_notice()
      |> reject_empty_profile()
      |> Map.put(:actions, Onboarding.list_actions(user.id))
      |> Map.put(:vault_count, Engram.Vaults.count_for(user))

    json(conn, payload)
  end

  def record(conn, %{"action" => action}) when is_binary(action) do
    user = conn.assigns.current_user

    case Onboarding.record_action(user.id, action) do
      :ok ->
        json(conn, %{status: "ok"})

      {:error, %Ecto.Changeset{}} ->
        conn |> put_status(422) |> json(%{error: "invalid_action"})
    end
  end

  def record(conn, _params) do
    conn |> put_status(422) |> json(%{error: "missing_action"})
  end

  # Drop terms_notice from the wire when there's nothing to notify.
  defp reject_nil_notice(%{terms_notice: nil} = s), do: Map.delete(s, :terms_notice)
  defp reject_nil_notice(s), do: s

  # Drop profile from the wire until the user has actually saved one — keeps
  # the questionnaire-incomplete payload identical to its pre-profile shape.
  defp reject_empty_profile(%{profile: nil} = s), do: Map.delete(s, :profile)

  defp reject_empty_profile(%{profile: profile} = s) when map_size(profile) == 0,
    do: Map.delete(s, :profile)

  defp reject_empty_profile(s), do: s

  def accept_terms(conn, %{
        "tos_version" => tv,
        "tos_hash" => th,
        "privacy_version" => pv,
        "privacy_hash" => ph
      }) do
    # Verify BOTH documents' version + content hash against the canonical
    # terms_versions table (via the cache). Any mismatch means the app is
    # showing different text than the backend expects (drift) — refuse with 409
    # instead of recording bad consent.
    ok =
      th == VersionCache.hash_for("terms_of_service", tv) and th != nil and
        ph == VersionCache.hash_for("privacy_policy", pv) and ph != nil and
        tv == VersionCache.current_version("terms_of_service") and
        pv == VersionCache.current_version("privacy_policy")

    if ok do
      meta = %{
        ip_address: RequestMeta.format_ip(conn.remote_ip),
        user_agent: RequestMeta.get_user_agent(conn)
      }

      case Onboarding.accept_terms(conn.assigns.current_user, tv, th, pv, ph, meta) do
        {:ok, agreement} ->
          conn
          |> put_status(:created)
          |> json(%{version: agreement.version, accepted_at: agreement.accepted_at})

        {:error, _changeset} ->
          conn |> put_status(422) |> json(%{error: "invalid"})
      end
    else
      conn |> put_status(409) |> json(%{error: "stale"})
    end
  end

  def accept_terms(conn, _params) do
    conn |> put_status(422) |> json(%{error: "missing_fields"})
  end

  # Free-tier acceptance: user clicked "Continue with Free" on /onboard/billing.
  # Stamps `free_tier_accepted_at` (idempotent — Onboarding.accept_free_tier/1
  # returns {:ok, user} unchanged if already set). Returns the same status
  # payload shape as GET /api/onboarding/status so the SPA can navigate to the
  # next step (`:billing` -> `:tools`/`:vault`/`:done`) without a second fetch.
  def accept_free_tier(conn, _params) do
    user = conn.assigns.current_user

    with {:ok, updated} <- Onboarding.accept_free_tier(user) do
      payload =
        Onboarding.status(updated)
        |> Map.update!(:next_step, &Atom.to_string/1)
        |> Map.update!(:steps, fn steps -> Enum.map(steps, &Atom.to_string/1) end)
        |> reject_nil_notice()
        |> reject_empty_profile()

      json(conn, payload)
    end
  end

  # FTUX questionnaire submit. Body shape (either or both):
  #   { tools: [string] }              — submitted from /onboard/tools
  #   { uses_obsidian: bool }          — submitted from /onboard/vault
  #   { tools: [...], uses_obsidian }  — combined (e.g. mid-flow re-POST)
  # The Onboarding context owns validation (catalog membership + non-empty
  # + boolean type); we render its error atom verbatim as the JSON error
  # so the SPA can switch on a stable string instead of a translated message.
  def set_profile(conn, params) do
    attrs =
      %{}
      |> maybe_put_attr(params, "tools", :tools)
      |> maybe_put_attr(params, "uses_obsidian", :uses_obsidian)

    if attrs == %{} do
      conn |> put_status(422) |> json(%{error: "missing_fields"})
    else
      case Onboarding.set_profile(conn.assigns.current_user, attrs) do
        {:ok, user} ->
          conn |> put_status(:created) |> json(user.onboarding_profile)

        {:error, reason}
        when reason in [:invalid_uses_obsidian, :empty_tools, :invalid_tool] ->
          conn |> put_status(422) |> json(%{error: Atom.to_string(reason)})
      end
    end
  end

  defp maybe_put_attr(attrs, params, json_key, atom_key) do
    case Map.fetch(params, json_key) do
      {:ok, value} -> Map.put(attrs, atom_key, value)
      :error -> attrs
    end
  end
end
