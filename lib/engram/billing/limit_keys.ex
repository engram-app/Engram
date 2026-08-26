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
    # Every tier gets the full MimeWhitelist surface (images, audio, video,
    # PDFs, office docs). Free used to be text/* only, which made
    # `attachment_bytes_cap` unreachable — 10k notes of markdown is ~50 MB
    # against a 1 GiB quota, so the quota never bound and the real Free limit
    # was an invisible MIME rule. Worse, a normal Obsidian vault silently
    # synced without its images, which reads as a broken product rather than a
    # limited tier. Storage is now the honest lever: the 1 GiB cap binds, and
    # a maxed Free user costs ~$0.02/mo of S3.
    #
    # POLARITY IS LOAD-BEARING. This replaces `attachments_text_only`, whose
    # `true` meant "restriction ON" — the only inverted boolean in this catalog.
    # `normalize_capability/2` maps `:unlimited` (enforcement off) to `true` for
    # every boolean, which is correct ONLY for grant-shaped flags. Under the old
    # inverted key that rule read as "restriction ON", so turning enforcement
    # OFF silently turned the restriction ON and every self-hoster lost images
    # and PDFs. Keep every boolean here grant-shaped (`true` == the user gets
    # the thing) and that whole failure class cannot come back.
    attachments_all_types: %{
      type: :boolean,
      defaults: %{free: true, starter: true, pro: true}
    },
    max_file_bytes: %{
      type: :integer,
      defaults: %{free: 10_485_760, starter: 209_715_200, pro: 524_288_000}
    },
    lifetime_embed_token_cap: %{
      type: :integer,
      defaults: %{free: 20_000_000, starter: nil, pro: nil}
    },
    # Free gets 2 so the tier can actually DEMONSTRATE sync — laptop + phone is
    # the floor for an Obsidian user, and a 1-device free tier can never show
    # the thing it is selling. The 3rd device is the upgrade trigger.
    #
    # PAIRED WITH `obsidian_connections_cap`. Both keys gate the same count
    # (`Connections.count_active(user.id, :obsidian)`) at two different
    # endpoints: this one on the device-flow authorize (`EnforceDeviceCap`),
    # that one on OAuth consent (`EnforceConnectionCap`). Raise one without the
    # other and the un-raised path still 402s at the old number.
    concurrent_devices: %{type: :integer, defaults: %{free: 2, starter: nil, pro: nil}},
    # Kept at 24h alongside the 2-device cap: it closes the revoke-and-re-add
    # rotation hole that would otherwise make the device cap advisory.
    device_swap_cooldown_hours: %{type: :integer, defaults: %{free: 24, starter: 0, pro: 0}},
    ai_conversations_per_day: %{type: :integer, defaults: %{free: 5, starter: nil, pro: nil}},
    ai_queries_per_conversation: %{
      type: :integer,
      defaults: %{free: 50, starter: nil, pro: nil}
    },
    # Starter at 150/day, not 500. A heavy Claude user runs ~50-200/day, so a
    # 500 ceiling never binds and the Starter -> Pro AI ladder does nothing.
    # 150 is a starting number, not a researched one — raise it on real usage
    # data (raising is the safe direction; lowering post-launch is not).
    ai_queries_per_day: %{type: :integer, defaults: %{free: nil, starter: 150, pro: 10_000}},
    conversation_window_minutes: %{type: :integer, defaults: %{free: 30, starter: 30, pro: 30}},
    reranker_enabled: %{type: :boolean, defaults: %{free: false, starter: false, pro: true}},
    # API KEYS ARE PRO-ONLY. Both keys gate ONLY API-key-authed traffic:
    # `RequireApiWriteEnabled` and `RequireApiRpsBudget` exempt any request
    # without `:current_api_key`, and `ChannelGate.api_access/2` only rejects
    # when the cap is 0 for an API-key socket. MCP and the Obsidian plugin
    # authenticate as `:internal_jwt` and the web app as a Clerk JWT — none of
    # them set `:current_api_key`, so Starter keeps full MCP + vault sync +
    # web app. Only programmatic access via a personal API key moves to Pro.
    api_write_enabled: %{type: :boolean, defaults: %{free: false, starter: false, pro: true}},
    # 0 means "an API key cannot make a single call" — REST via
    # `RequireApiRpsBudget`, socket via `ChannelGate`. Keep this at 0 on any
    # tier where `api_write_enabled` is false, or a key gets read access to
    # the whole vault through the sync socket while REST writes are refused.
    api_rps_cap: %{type: :integer, defaults: %{free: 0, starter: 0, pro: 30}},
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
    # Grant-shaped, like every other boolean here: `true` == this user is
    # EXEMPT from the free-tier inactivity dunning. Was `inactivity_warn_60_days`
    # (free: true), which is the same inverted shape that broke attachments —
    # enforcement off resolved to `:unlimited` -> `true` -> "warn them", so
    # self-hosters got free-tier inactivity warnings on their own hardware.
    inactivity_warnings_exempt: %{
      type: :boolean,
      defaults: %{free: false, starter: true, pro: true}
    },
    inactivity_delete_days: %{type: :integer, defaults: %{free: 90, starter: nil, pro: nil}},
    # Legacy keys preserved for back-compat with existing call sites
    cross_vault_search: %{type: :boolean, defaults: %{free: false, starter: false, pro: true}},
    vault_scoped_keys: %{type: :boolean, defaults: %{free: false, starter: true, pro: true}},
    # Connections caps — paid tiers unlimited. `obsidian_connections_cap` MUST
    # track `concurrent_devices` (see the note there): same underlying count,
    # two enforcement points.
    obsidian_connections_cap: %{type: :integer, defaults: %{free: 2, starter: nil, pro: nil}},
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
    },
    # Search-quality dials (per-tier, live-tunable via SearchProfile)
    search_full_precision: %{type: :boolean, defaults: %{free: false, starter: false, pro: false}},
    search_diversity: %{type: :integer, defaults: %{free: 30, starter: 30, pro: 30}},
    search_candidate_pool: %{type: :integer, defaults: %{free: 20, starter: 20, pro: 30}},
    search_query_model: %{type: :string, defaults: %{free: nil, starter: nil, pro: nil}}
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

  @spec type(atom()) :: :integer | :boolean | :string
  def type(key) when key in @keys, do: @catalog |> Map.fetch!(key) |> Map.fetch!(:type)

  @spec default_for(atom(), atom()) :: integer() | boolean() | String.t() | nil
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
