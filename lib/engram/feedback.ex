defmodule Engram.Feedback do
  @moduledoc """
  User-voice answers: how a signup heard about us and what they want Engram for
  (asked on `/onboard/tools`), why a subscriber cancels, and free-form feedback.

  Every answer goes to PostHog server-side (ad blockers cannot drop it), with
  the slugs also set as person properties so dashboards can break funnels down
  by them. The onboarding answers are also merged into
  `users.onboarding_profile`, so they survive a PostHog outage and self-host.
  Answering is always optional: nothing gates on these fields.
  """

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Observability.PostHog
  alias Engram.Repo

  @heard_from ~w(search reddit youtube obsidian_community friend ai_assistant social other)
  @use_cases ~w(ai_memory obsidian_sync web_access search backup sharing other)
  @cancel_reasons ~w(too_expensive missing_feature sync_issues switched_tool not_using other)
  @max_text 2_000

  def heard_from_options, do: @heard_from
  def use_case_options, do: @use_cases
  def cancel_reason_options, do: @cancel_reasons

  @type error ::
          :invalid_kind
          | :nothing_to_set
          | :invalid_heard_from
          | :invalid_use_cases
          | :invalid_reason
          | :empty_message

  @spec submit(User.t(), String.t(), map()) :: :ok | {:error, error()}
  def submit(user, "onboarding", params) do
    with {:ok, fields} <- onboarding_fields(params) do
      from(u in User,
        where: u.id == ^user.id,
        update: [set: [onboarding_profile: fragment("? || ?", u.onboarding_profile, ^fields)]]
      )
      |> Repo.update_all([], skip_tenant_check: true)

      capture(user, "onboarding_survey_answered", %{
        "detail" => fields["survey_detail"],
        "$set" => Map.take(fields, ["heard_from", "use_cases"])
      })
    end
  end

  def submit(user, "cancel", %{"reason" => reason} = params) when reason in @cancel_reasons do
    capture(user, "subscription_cancel_reason", %{
      "reason" => reason,
      "detail" => text(params["detail"]),
      "$set" => %{"cancel_reason" => reason}
    })
  end

  def submit(_user, "cancel", _params), do: {:error, :invalid_reason}

  def submit(user, "general", params) do
    case text(params["message"]) do
      nil -> {:error, :empty_message}
      message -> capture(user, "user_feedback", %{"message" => message})
    end
  end

  def submit(_user, _kind, _params), do: {:error, :invalid_kind}

  defp onboarding_fields(params) do
    heard_from = params["heard_from"]
    use_cases = params["use_cases"]

    cond do
      not (is_nil(heard_from) or heard_from in @heard_from) ->
        {:error, :invalid_heard_from}

      not (is_nil(use_cases) or (is_list(use_cases) and Enum.all?(use_cases, &(&1 in @use_cases)))) ->
        {:error, :invalid_use_cases}

      is_nil(heard_from) and use_cases in [nil, []] ->
        {:error, :nothing_to_set}

      true ->
        fields =
          %{
            "heard_from" => heard_from,
            "use_cases" => if(use_cases in [nil, []], do: nil, else: Enum.uniq(use_cases)),
            "survey_detail" => text(params["detail"])
          }
          |> Map.reject(fn {_k, v} -> is_nil(v) end)

        {:ok, fields}
    end
  end

  # Free text is trimmed and capped; blank means absent.
  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, @max_text)
    end
  end

  defp text(_), do: nil

  # A user with no email has no analytics id; their answer still lands in the
  # profile (onboarding) but has nowhere to go in PostHog.
  defp capture(%{email: email}, event, props) when is_binary(email) do
    PostHog.capture(
      PostHog.analytics_id(email),
      event,
      Map.reject(props, fn {_k, v} -> is_nil(v) end)
    )
  end

  defp capture(_user, _event, _props), do: :ok
end
