defmodule Engram.Billing.LimitKeys do
  @moduledoc """
  Compile-time catalog of plan limit keys.

  Single source of truth for the per-tier limit matrix. `nil` in
  defaults means "unlimited" (no enforcement). Use:

    LimitKeys.defined?(:notes_cap)            #=> true
    LimitKeys.type(:notes_cap)                #=> :integer
    LimitKeys.default_for(:notes_cap, :free)  #=> 10_000
    LimitKeys.env_var_names()                 #=> 81 tuples (27 keys × 3 tiers)
  """

  @catalog %{
    # Pricing v2 spec §9.2 — 17 keys
    notes_cap: %{type: :integer, defaults: %{free: 10_000, starter: 50_000, pro: nil}},
    vaults_cap: %{type: :integer, defaults: %{free: 1, starter: 5, pro: 15}},
    attachment_bytes_cap: %{
      type: :integer,
      defaults: %{free: 1_073_741_824, starter: 3_221_225_472, pro: 16_106_127_360}
    },
    attachments_enabled: %{type: :boolean, defaults: %{free: true, starter: true, pro: true}},
    # Free is restricted to text/* uploads only; Starter+ get the full
    # MimeWhitelist surface (images, audio, video, PDFs, office docs).
    # `true` means "Free-style restriction is ON" so the gate matches
    # the pattern of every other paid-feature boolean.
    attachments_text_only: %{
      type: :boolean,
      defaults: %{free: true, starter: false, pro: false}
    },
    max_file_bytes: %{
      type: :integer,
      defaults: %{free: 10_485_760, starter: 209_715_200, pro: 524_288_000}
    },
    lifetime_embed_token_cap: %{
      type: :integer,
      defaults: %{free: 20_000_000, starter: nil, pro: nil}
    },
    concurrent_devices: %{type: :integer, defaults: %{free: 1, starter: nil, pro: nil}},
    device_swap_cooldown_hours: %{type: :integer, defaults: %{free: 24, starter: 0, pro: 0}},
    ai_conversations_per_day: %{type: :integer, defaults: %{free: 5, starter: nil, pro: nil}},
    ai_queries_per_conversation: %{
      type: :integer,
      defaults: %{free: 50, starter: nil, pro: nil}
    },
    ai_queries_per_day: %{type: :integer, defaults: %{free: nil, starter: 500, pro: 10_000}},
    conversation_window_minutes: %{type: :integer, defaults: %{free: 30, starter: 30, pro: 30}},
    reranker_enabled: %{type: :boolean, defaults: %{free: false, starter: false, pro: true}},
    api_write_enabled: %{type: :boolean, defaults: %{free: false, starter: true, pro: true}},
    api_rps_cap: %{type: :integer, defaults: %{free: 0, starter: 10, pro: 30}},
    # Rolling-24h search caps on the Free tier. Split by where the request
    # came from so a noisy MCP / PAT bot can't burn the user's in-app
    # budget and vice-versa. Both fire on POST /api/search only — note
    # reads, manifest pulls, attachment fetches are NOT counted.
    #
    # `external_ai_searches_per_day`: API-key + OAuth + device-flow + MCP
    # access. Tight number on Free because the abuse vector is automated.
    # `inapp_searches_per_day`: Web SPA (Clerk JWT). Generous because the
    # cap exists for spam defense, not to throttle the user in the app.
    external_ai_searches_per_day: %{type: :integer, defaults: %{free: 15, starter: nil, pro: nil}},
    inapp_searches_per_day: %{type: :integer, defaults: %{free: 60, starter: nil, pro: nil}},
    inactivity_warn_60_days: %{
      type: :boolean,
      defaults: %{free: true, starter: false, pro: false}
    },
    inactivity_delete_days: %{type: :integer, defaults: %{free: 90, starter: nil, pro: nil}},
    # Legacy keys preserved for back-compat with existing call sites
    cross_vault_search: %{type: :boolean, defaults: %{free: false, starter: false, pro: true}},
    vault_scoped_keys: %{type: :boolean, defaults: %{free: false, starter: true, pro: true}},
    # Connections caps — free tier capped at 1; paid tiers unlimited
    obsidian_connections_cap: %{type: :integer, defaults: %{free: 1, starter: nil, pro: nil}},
    mcp_connections_cap: %{type: :integer, defaults: %{free: 1, starter: nil, pro: nil}},
    # Account export caps — free gets 1 lifetime, paid tiers get 1/24h with 200 GB size cap
    account_exports_lifetime: %{type: :integer, defaults: %{free: 1, starter: nil, pro: nil}},
    account_export_rate_per_24h: %{
      type: :integer,
      defaults: %{free: nil, starter: 1, pro: 1}
    },
    account_export_max_bytes: %{
      type: :integer,
      defaults: %{free: 1_000_000_000, starter: 200_000_000_000, pro: 200_000_000_000}
    }
  }

  @keys Map.keys(@catalog)
  @tiers [:free, :starter, :pro]

  @spec all() :: [atom(), ...]
  def all, do: @keys

  @spec tiers() :: [:free | :starter | :pro, ...]
  def tiers, do: @tiers

  @spec defined?(any()) :: boolean()
  def defined?(key) when is_atom(key), do: key in @keys
  def defined?(_), do: false

  @spec type(atom()) :: :integer | :boolean
  def type(key) when key in @keys, do: @catalog |> Map.fetch!(key) |> Map.fetch!(:type)

  @spec default_for(atom(), atom()) :: integer() | boolean() | nil
  def default_for(key, tier) when key in @keys and tier in @tiers,
    do: @catalog |> Map.fetch!(key) |> Map.fetch!(:defaults) |> Map.fetch!(tier)

  @spec env_var_names() :: [{atom(), atom(), String.t()}]
  def env_var_names do
    for tier <- @tiers, key <- @keys do
      env =
        "ENGRAM_#{tier |> to_string() |> String.upcase()}_#{key |> to_string() |> String.upcase()}"

      {tier, key, env}
    end
  end
end
