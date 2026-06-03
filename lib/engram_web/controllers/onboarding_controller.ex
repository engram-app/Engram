defmodule EngramWeb.OnboardingController do
  use EngramWeb, :controller

  alias Engram.Legal.VersionCache
  alias Engram.Onboarding
  alias EngramWeb.RequestMeta

  def status(conn, _params) do
    user = conn.assigns.current_user

    payload =
      case Onboarding.status(user) do
        %{enabled: false} = s ->
          %{enabled: false, next_step: Atom.to_string(s.next_step)}

        %{enabled: true} = s ->
          s
          |> Map.update!(:next_step, &Atom.to_string/1)
          |> reject_nil_notice()
          |> reject_empty_profile()
      end

    json(conn, payload)
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

  # FTUX questionnaire submit. Body shape:
  #   { uses_obsidian: bool, tools: [string] }
  # The Onboarding context owns validation (catalog membership + non-empty
  # + boolean type); we render its error atom verbatim as the JSON error
  # so the SPA can switch on a stable string instead of a translated message.
  def set_profile(conn, %{"uses_obsidian" => uses_obsidian, "tools" => tools})
      when is_list(tools) do
    case Onboarding.set_profile(conn.assigns.current_user, %{
           uses_obsidian: uses_obsidian,
           tools: tools
         }) do
      {:ok, user} ->
        conn |> put_status(:created) |> json(user.onboarding_profile)

      {:error, reason} when reason in [:invalid_uses_obsidian, :empty_tools, :invalid_tool] ->
        conn |> put_status(422) |> json(%{error: Atom.to_string(reason)})
    end
  end

  def set_profile(conn, _params) do
    conn |> put_status(422) |> json(%{error: "missing_fields"})
  end
end
