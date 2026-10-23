defmodule Engram.Analytics.ClientEvents do
  @moduledoc """
  The web app's own events (`frontend/src/analytics/events.ts`), validated
  server-side before `POST /api/analytics/events` records them in the event
  log. A mirror of the SPA's `EVENT_SCHEMAS` and `isKind`, because the
  browser is not trusted: every event must be declared, every key declared
  for its event, every value of its declared kind, or the whole event is
  dropped (a partial event is a silent lie, as in `track.ts`). There is no
  free-text kind.

  A test pins the event names to `events.ts`.
  """

  @steps ~w(agreement billing heard vault done)
  @kinds %{
    "step" => @steps,
    "checkout_method" => ~w(card apple_pay google_pay paypal unknown),
    "tier" => ~w(starter pro),
    "mcp_client" => ~w(chatgpt claude cursor other),
    "upgrade_source" => ~w(checklist paywall direct),
    "cadence" => ~w(monthly annual),
    "limit_reason" => ~w(notes_cap_exceeded vaults_cap_exceeded attachments_disabled
      attachments_quota_exceeded file_too_large concurrent_devices_exceeded device_swap_cooldown
      ai_searches_per_day_exceeded attachment_must_be_text obsidian_connections_exceeded
      account_suspended no_tier other),
    "checklist_item" => ~w(vault join_discord install_obsidian_plugin claude chatgpt grok mistral
      open_webui lobechat muse claude_code cursor devin windsurf cline continue opencode
      github_copilot antigravity other_mcp),
    "checklist_action" => ~w(guide_opened dismissed),
    "vault_source" => ~w(obsidian fresh),
    "error_code" => ~w(onboarding_required gate_closed not_found rate_limited network timeout
      payment_declined payment_unfinished limit_exceeded unknown),
    "gate_reasons" => ~w(terms subscription profile vault),
    "locale" => Engram.I18n.locales()
  }

  @schemas %{
    "onboarding_step_viewed" => %{"step" => "step"},
    "onboarding_step_completed" => %{
      "step" => "step",
      "vault_id" => "uuid",
      "duration_ms" => "number"
    },
    "onboarding_blocked" => %{"missing" => "gate_reasons", "next_step" => "step"},
    "plugin_connect_started" => %{"vault_id" => "uuid"},
    "plugin_connect_succeeded" => %{"vault_id" => "uuid", "duration_ms" => "number"},
    "plugin_connect_failed" => %{"vault_id" => "uuid", "reason" => "error_code"},
    "vault_first_sync_completed" => %{
      "vault_id" => "uuid",
      "note_count" => "number",
      "duration_ms" => "number"
    },
    "checkout_opened" => %{
      "method" => "checkout_method",
      "tier" => "tier",
      "cadence" => "cadence",
      "source" => "upgrade_source"
    },
    "checkout_stalled" => %{"method" => "checkout_method", "reason" => "error_code"},
    "checkout_completed" => %{"method" => "checkout_method"},
    "checkout_abandoned" => %{"method" => "checkout_method", "reason" => "error_code"},
    "mcp_connect_attempted" => %{"client" => "mcp_client"},
    "mcp_connect_succeeded" => %{"client" => "mcp_client"},
    "mcp_connect_failed" => %{"client" => "mcp_client", "reason" => "error_code"},
    "mcp_connect_denied" => %{"client" => "mcp_client"},
    "upgrade_link_clicked" => %{"source" => "upgrade_source"},
    "checklist_action" => %{"item" => "checklist_item", "action" => "checklist_action"},
    "vault_source_picked" => %{"source" => "vault_source"},
    "plugin_listing_opened" => %{},
    "paywall_shown" => %{"limit_key" => "limit_reason"},
    "browser_languages_unsupported" => %{"languages" => "language_tags"},
    "browser_translation_detected" => %{"to" => "language_tag", "app_locale" => "locale"}
  }

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  # Same shape as track.ts LANGUAGE_TAG: a BCP 47 tag, never free text.
  @language_tag ~r/\A[a-z]{2,3}(?:-[A-Za-z0-9]{2,8}){0,3}\z/

  # A duration or a count: anything larger is not a real measurement.
  @max_number 1_000_000_000

  @doc "Every event name the web app may send."
  @spec names() :: [String.t()]
  def names, do: Map.keys(@schemas)

  @doc """
  `{:ok, event, props}` when `raw` (`%{"event" => name, "props" => map}`) is a
  declared event whose every prop is declared and of its kind, else `:error`.
  """
  @spec validate(term()) :: {:ok, String.t(), map()} | :error
  def validate(%{"event" => event} = raw) when is_map_key(@schemas, event) do
    props = Map.get(raw, "props") || %{}
    schema = Map.fetch!(@schemas, event)

    if is_map(props) and Enum.all?(props, fn {k, v} -> kind?(schema[k], v) end),
      do: {:ok, event, props},
      else: :error
  end

  def validate(_raw), do: :error

  defp kind?(nil, _value), do: false
  defp kind?("uuid", v), do: is_binary(v) and v =~ @uuid
  defp kind?("number", v), do: is_number(v) and abs(v) <= @max_number

  defp kind?("boolean", v), do: is_boolean(v)
  defp kind?("language_tag", v), do: is_binary(v) and v =~ @language_tag

  defp kind?("language_tags", v),
    do: is_list(v) and length(v) <= 16 and Enum.all?(v, &kind?("language_tag", &1))

  defp kind?("gate_reasons", v),
    do: is_list(v) and length(v) <= 4 and Enum.all?(v, &(&1 in @kinds["gate_reasons"]))

  defp kind?(kind, v), do: v in Map.fetch!(@kinds, kind)
end
