defmodule Engram.Feedback do
  @moduledoc """
  User-voice answers: how a signup heard about us and what they want Engram for
  (asked on `/onboard/about`), why a subscriber cancels or deletes their account,
  and free-form feedback.

  Every answer goes to PostHog server-side (ad blockers cannot drop it), with
  the slugs also set as person properties so dashboards can break funnels down
  by them. The onboarding answers are also merged into
  `users.onboarding_profile`, so they survive a PostHog outage and self-host.
  Answering is always optional. An empty onboarding submission (Continue with
  nothing picked) is a skip: it stamps `survey_done_at` (as an answer does), which is the only
  thing the wizard's `:about` step waits on.
  """

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Billing
  alias Engram.Observability.PostHog
  alias Engram.Repo

  @heard_from ~w(search reddit youtube obsidian_community obsidian_plugins friend ai_assistant social other)
  @use_cases ~w(ai_memory obsidian_sync web_access search backup sharing other)
  @cancel_reasons ~w(too_expensive missing_feature sync_issues switched_tool not_using other)
  @categories ~w(bug idea confusing love missing_capability)
  @sources ~w(web plugin mcp)
  @initiators ~w(user model)
  # Each submit is a billed PostHog event with up to 2,000 chars of free text,
  # shared by every surface (web, plugin, MCP), so one budget covers them all.
  @hourly_limit 20
  @model_hourly_limit 5
  @max_text 2_000

  # Client context must be a plain token: anything else (a newline, an email,
  # free text) is dropped rather than stored as an analytics property.
  @version_format ~r/\A[\w.+-]{1,40}\z/u
  @area_format ~r/\A[\w.\/-]{1,80}\z/u
  @tool_name_format ~r/\A[a-z_]{1,64}\z/

  def heard_from_options, do: @heard_from
  def use_case_options, do: @use_cases
  def cancel_reason_options, do: @cancel_reasons

  @type error ::
          :invalid_kind
          | :invalid_heard_from
          | :invalid_use_cases
          | :invalid_reason
          | :empty_message
          | :invalid_category
          | :invalid_mood
          | :invalid_source
          | :invalid_initiated_by

  @doc """
  Spend one unit of the user's hourly feedback budget. Feedback a model sends
  unasked (MCP `initiated_by: "model"`) draws on its own smaller budget, so a
  session of failing tools cannot use up the user's own.
  """
  @spec allow?(User.t(), :user | :model) :: boolean()
  def allow?(user, by \\ :user)

  def allow?(user, :user), do: hit("feedback:#{user.id}", @hourly_limit)
  def allow?(user, :model), do: hit("feedback:model:#{user.id}", @model_hourly_limit)

  defp hit(key, limit),
    do: match?({:allow, _}, EngramWeb.RateLimiter.hit(key, :timer.hours(1), limit, :feedback))

  @doc "Whether feedback reaches anyone: false on self-host, where analytics is off."
  @spec collected?() :: boolean()
  def collected?, do: PostHog.enabled?()

  @spec submit(User.t(), String.t(), map()) :: :ok | {:error, error()}
  def submit(user, "onboarding", params) do
    with {:ok, fields} <- onboarding_fields(params) do
      stamped =
        Map.put(fields, "survey_done_at", DateTime.utc_now(:second) |> DateTime.to_iso8601())

      from(u in User,
        where: u.id == ^user.id,
        update: [set: [onboarding_profile: fragment("? || ?", u.onboarding_profile, ^stamped)]]
      )
      # Same as Onboarding.set_profile/2: `users` is the tenant root, not a
      # tenant-scoped table, and the write is keyed to the caller's own id.
      |> Repo.update_all([], skip_tenant_check: true)

      # Onboarding.status/1 reads the cached user row; without this the wizard
      # keeps answering `:about` after the stamp lands.
      Engram.Accounts.evict_user(user.id)

      if fields == %{} do
        :ok
      else
        capture(
          user,
          "onboarding_survey_answered",
          # The slugs ride on the event as well as in $set: PostHog applies
          # $set to the person and drops it from the stored event.
          fields
          |> Map.take(["heard_from", "use_cases", "use_cases_detail", "heard_from_detail"])
          |> Map.put("$set", Map.take(fields, ["heard_from", "use_cases"]))
        )
      end
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

  # Stashed on the user row, not sent: the browser sends this BEFORE the
  # delete (afterwards there is no session to send it with), so sending now
  # would record reasons for deletes that are cancelled or retried. Erasure
  # sends it via `capture_delete_reason/1` once the account is really gone. A
  # second submit overwrites the first. The reason is optional here: erasure
  # must never be gated on giving feedback.
  def submit(user, "delete_account", params) do
    reason = params["reason"]
    detail = params["detail"] |> text() |> scrub_emails()

    cond do
      not (is_nil(reason) or reason in @cancel_reasons) ->
        {:error, :invalid_reason}

      is_nil(reason) and is_nil(detail) ->
        {:error, :empty_message}

      true ->
        stash = %{"delete_reason" => reason, "delete_detail" => detail}

        from(u in User,
          where: u.id == ^user.id,
          update: [set: [onboarding_profile: fragment("? || ?", u.onboarding_profile, ^stash)]]
        )
        # Keyed to the caller's own id; see the onboarding clause above.
        |> Repo.update_all([], skip_tenant_check: true)

        :ok
    end
  end

  def submit(user, "general", params) do
    with {:ok, message} <- required_message(params["message"]),
         {:ok, props} <- general_props(user, params) do
      capture(user, "user_feedback", Map.put(props, "message", message))
    end
  end

  def submit(_user, _kind, _params), do: {:error, :invalid_kind}

  @doc """
  Send the answer stashed by a `delete_account` submit, given the user's
  `onboarding_profile` read before the row was deleted. Anonymous on purpose:
  erasure deletes the person AND their events from PostHog, which would take a
  person-keyed answer with it. A fresh distinct_id with no person profile keeps
  the reason and drops who gave it.
  """
  @spec capture_delete_reason(map() | nil) :: :ok
  def capture_delete_reason(%{} = profile) do
    case {profile["delete_reason"], profile["delete_detail"]} do
      {nil, nil} ->
        :ok

      {reason, detail} ->
        PostHog.capture(
          Ecto.UUID.generate(),
          "account_delete_reason",
          Map.reject(
            %{"reason" => reason, "detail" => detail, "$process_person_profile" => false},
            fn {_k, v} -> is_nil(v) end
          )
        )
    end
  end

  def capture_delete_reason(_profile), do: :ok

  defp onboarding_fields(params) do
    heard_from = params["heard_from"]
    use_cases = params["use_cases"]

    cond do
      not (is_nil(heard_from) or heard_from in @heard_from) ->
        {:error, :invalid_heard_from}

      not (is_nil(use_cases) or (is_list(use_cases) and Enum.all?(use_cases, &(&1 in @use_cases)))) ->
        {:error, :invalid_use_cases}

      true ->
        fields =
          %{
            "heard_from" => heard_from,
            "use_cases" => if(use_cases in [nil, []], do: nil, else: Enum.uniq(use_cases)),
            "use_cases_detail" => text(params["use_cases_detail"]),
            "heard_from_detail" => text(params["heard_from_detail"])
          }
          |> Map.reject(fn {_k, v} -> is_nil(v) end)

        {:ok, fields}
    end
  end

  defp required_message(value) do
    case text(value) do
      nil -> {:error, :empty_message}
      message -> {:ok, message}
    end
  end

  # Category, mood and reply consent come from the user; source, version and
  # area from the client; plan, server version and user agent from the server
  # (the controller stamps the request's user agent over any sent in the body).
  defp general_props(user, params) do
    category = params["category"]
    mood = params["mood"]
    source = params["source"] || "web"
    initiated_by = params["initiated_by"]

    cond do
      not (is_nil(category) or category in @categories) ->
        {:error, :invalid_category}

      not (is_nil(mood) or (is_integer(mood) and mood in 1..5)) ->
        {:error, :invalid_mood}

      source not in @sources ->
        {:error, :invalid_source}

      not (is_nil(initiated_by) or initiated_by in @initiators) ->
        {:error, :invalid_initiated_by}

      true ->
        props =
          %{
            "category" => category,
            "mood" => mood,
            "contact_ok" => params["contact_ok"] == true,
            # Only with consent: the one place a reply address is stored.
            "contact_email" => if(params["contact_ok"] == true, do: user.email),
            "source" => source,
            # MCP only: whether the user asked, or the model filed it unasked.
            "initiated_by" => initiated_by,
            "tool_name" => token(params["tool_name"], @tool_name_format),
            "app_version" => token(params["app_version"], @version_format),
            "area" => token(params["area"], @area_format),
            "user_agent" => text(params["user_agent"], 300),
            "plan" => user |> Billing.tier() |> Atom.to_string(),
            "server_version" => server_version()
          }
          |> Map.reject(fn {_k, v} -> is_nil(v) end)

        {:ok, props}
    end
  end

  defp server_version do
    vsn = :engram |> Application.spec(:vsn) |> to_string()

    case System.get_env("RELEASE_SHA") do
      sha when is_binary(sha) and sha != "" -> "#{vsn} (#{String.slice(sha, 0, 7)})"
      _ -> vsn
    end
  end

  defp token(value, format) when is_binary(value) do
    trimmed = String.trim(value)
    if Regex.match?(format, trimmed), do: trimmed
  end

  defp token(_, _), do: nil

  # Free text is trimmed and capped; blank means absent.
  defp text(value, max \\ @max_text)

  defp text(value, max) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, max)
    end
  end

  defp text(_, _), do: nil

  # The delete answer outlives the account with no link back to it, so an email
  # typed into it could never be found or erased later. Possessive quantifiers:
  # no backtracking on long input.
  defp scrub_emails(nil), do: nil

  defp scrub_emails(text),
    do: Regex.replace(~r/[^\s@]++@[^\s@.]++(?:\.[^\s@.]++)+/u, text, "[email]")

  # A user with no email has no analytics id; their answer still lands in the
  # profile (onboarding) but has nowhere to go in PostHog.
  defp capture(user, event, props) do
    PostHog.capture(
      PostHog.distinct_id(user),
      event,
      Map.reject(props, fn {_k, v} -> is_nil(v) end)
    )
  end
end
