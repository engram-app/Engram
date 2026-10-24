defmodule Engram.Billing.LimitKeys do
  @moduledoc """
  Compile-time catalog of plan limit keys.

  Single source of truth for the per-tier limit matrix. `nil` in
  defaults means "unlimited" (no enforcement). Use:

    LimitKeys.defined?(:notes_cap)            #=> true
    LimitKeys.type(:notes_cap)                #=> :integer
    LimitKeys.default_for(:notes_cap, :free)  #=> 3_000 (2_000 with v5 plan limits)
    LimitKeys.env_var_names()                 #=> one tuple per key per tier
  """

  @catalog %{
    # Pricing v2 spec §9.2 — 17 keys
    # 3,000 / 50,000 / unlimited notes stored (2026-10-17), until the v5 go
    # flag (`plan_limits/0`) switches to 2,000 / 20,000 / 40,000 (owner
    # decision 2026-10-19). Every stored note is searchable: the upgrade
    # levers are `ai_searches_per_day` and `vaults_cap`, not search coverage,
    # and the separate `indexed_notes_cap` was removed.
    notes_cap: %{
      type: :integer,
      defaults: %{free: 3_000, starter: 50_000, pro: nil},
      v5_defaults: %{free: 2_000, starter: 20_000, pro: 40_000}
    },
    # Free index budget (spec: Engram vault `50 Engineering/_Superpowers Specs/
    # 2026-10-18-qdrant-storage-and-free-index-budget-design.md`). Bounds the
    # Qdrant points one account may hold, counted in `chunks` rows. Past the cap
    # notes are demoted to a floor point; sync and writes never fail on it.
    #
    # GOLDEN RULE: points cap = `notes_cap` x 6. The chunker v5 median is
    # about 5.2 points per note (min512 coalesce, per-note merge cap), so a
    # full account of median notes fits with headroom (owner approved
    # 2026-10-19; re-derive only if the v5 dry-run median leaves 5.0 to 6.5).
    # Change both together.
    index_points_cap: %{
      type: :integer,
      defaults: %{free: 12_000, starter: 120_000, pro: 240_000}
    },
    # Dense points one note may hold. A note chunked past it has adjacent
    # chunks merged into exactly this many points, so the whole note stays
    # covered (`Indexing.cap_chunks/3`). 641 prod notes over 128 chunks held
    # 62.6% of all points (2026-10-18 audit).
    note_points_cap: %{type: :integer, defaults: %{free: 128, starter: 1_024, pro: 1_024}},
    # PACKAGING, NOT A RESOURCE (pricing v3.1, 2026-09-03). An earlier draft
    # justified a Pro ceiling on per-vault CRDT index-room memory. That was
    # wrong three ways and is recorded so it is not re-derived:
    #   * `CrdtIndexDoc.start_link` sets `auto_exit: true` — rooms are
    #     demand-started and exit on last observer, so a vault nobody is
    #     connected to holds zero rooms and zero bytes.
    #   * `CrdtRoomLru.touch/3` only tracks rooms with a positive
    #     `idle_exit_ms`; the index room sets none, so it is never LRU-tracked
    #     and cannot evict another user's rooms.
    #   * Every quota here is per USER (`Billing.effective_limit(user, ...)`,
    #     `Notes.check_notes_cap/1`), so vault count multiplies nothing.
    # Residency tracks concurrent connections, which `concurrent_devices`
    # already bounds. Residual risk is scripted vault-row creation, which
    # belongs to the rate limiter, not to a pricing tier.
    vaults_cap: %{type: :integer, defaults: %{free: 1, starter: 10, pro: nil}},
    # 1 / 10 / 50 GiB. Raised from 1 / 3 / 15 GiB in pricing v3.1.
    #
    # THIS IS AN EGRESS CEILING WEARING A STORAGE LABEL. Downloads stream
    # through `AttachmentsController.show/2`, so every byte here is billed as
    # data transfer out at ~$0.09/GB — 4x the ~$0.023/GB-mo storage price —
    # and it is charged per device, per sync. A Pro user filling 50 GiB across
    # four devices moves 200 GiB on first sync, ~$18 against $14 of revenue.
    # DO NOT raise past 50 GiB until attachment downloads are edge-cached.
    attachment_bytes_cap: %{
      type: :integer,
      defaults: %{free: 1_073_741_824, starter: 10_737_418_240, pro: 53_687_091_200}
    },
    attachments_enabled: %{type: :boolean, defaults: %{free: true, starter: true, pro: true}},
    # Note version history (#1710). Grant-shaped (true = the user gets it),
    # per the polarity rule this file's tests pin. Every tier has history, so
    # this is a kill switch per tier or per user, gated in
    # Engram.Notes.Revisions.recording?/1. The retention keys
    # (history_max_versions, history_retention_days) land with their
    # enforcement in #1712: a catalog row without a gate is the dead-entry
    # pattern limit_keys_test.exs refuses.
    history_enabled: %{type: :boolean, defaults: %{free: true, starter: true, pro: true}},
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
    # Free's Voyage budget: the CAPACITY of a token bucket that refills
    # continuously at one capacity per 365 days (`UsageMeters.bucket_take/4`),
    # so 6M up front and ~16.4k a day after. Replaces the 20M LIFETIME cap,
    # which spent once and then stopped embedding a Free user forever. An empty
    # bucket never stops indexing: the pass runs keyword-only and the note is
    # re-embedded densely as tokens refill. nil (paid) = no bucket.
    embed_token_bucket: %{
      type: :integer,
      defaults: %{free: 6_000_000, starter: nil, pro: nil}
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
    reranker_enabled: %{type: :boolean, defaults: %{free: false, starter: false, pro: true}},
    # No `search_semantic_enabled` key: semantic search is every tier's. Free is
    # bounded by `notes_cap`, `embed_token_bucket` and
    # `ai_searches_per_day`, not by a feature flag.
    # API KEYS WORK EVERYWHERE, ON EVERY TIER (#1974). A personal API key may
    # call every route (REST, MCP, the sync sockets) on Free, Starter and Pro,
    # and there is no write flag: `api_write_enabled` and the MCP connection
    # cap were removed. Cost is metered where it is incurred, whatever the
    # credential: `ai_searches_per_day` at the search cost site
    # (`Engram.Search.search/4`) and `notes_cap` on
    # writes. Abuse is bounded by `PreAuthRateLimit` (600/min per endpoint
    # family) and this key.
    #
    # `api_rps_cap` is per user, per second, for API-KEY traffic only (REST via
    # `RequireApiRpsBudget`, which exempts requests without `:current_api_key`).
    # Kept as a key, not hardcoded, so a per-user override can lift it or set
    # it to 0: 0 refuses every API-key call, REST and socket
    # (`ChannelGate.api_access/2`), which is the per-user kill switch.
    api_rps_cap: %{type: :integer, defaults: %{free: 30, starter: 30, pro: 30}},
    # MCP `tools/call` requests per user per minute, for traffic WITHOUT an API
    # key (OAuth grants; API keys are already under `api_rps_cap`). Before it,
    # OAuth MCP was bounded only by `PreAuthRateLimit` (600/min per endpoint
    # family). Only `tools/call` counts: initialize, notifications, ping and
    # the list methods are protocol chatter. Gated in
    # `EngramWeb.McpController`; a refusal is 429 + Retry-After. A key, not a
    # constant, so an override can lift it for one heavy agent user, or set it
    # to 0: the per-user kill switch (every OAuth tools/call refused, no
    # Retry-After). One bucket per user, shared by all their OAuth connections.
    mcp_tool_calls_per_min: %{type: :integer, defaults: %{free: 120, starter: 120, pro: 120}},
    # THE AI usage meter. One key, one number, every transport.
    #
    # Charged in `Engram.Search.search/4` — the single funnel every retrieval
    # passes through (five call sites: four in `Engram.MCP.Handlers`, one in
    # `EngramWeb.SearchController`) and where the Voyage embed actually happens.
    # Charging at the COST SITE rather than at each transport means a new
    # caller is metered automatically. The previous design charged at the
    # transports against a hand-maintained list of "which MCP tools are
    # retrieval", which is how `external_ai_searches_per_day` went unenforced
    # on the entire MCP transport for months (#1527).
    #
    # Rolling, not calendar-daily: `Engram.Usage.DailyCap` is a token bucket
    # with continuous refill (capacity = allowance, refill = allowance/86_400
    # per second), so there is no midnight cliff and no cron.
    #
    # Replaces SIX keys that metered one user-visible concept through two
    # mechanisms: `external_ai_searches_per_day` (15) and
    # `inapp_searches_per_day` (60) — split by auth marker, which put the
    # Obsidian plugin in the "automated" bucket — plus
    # `ai_conversations_per_day` (5), `ai_queries_per_conversation` (50),
    # `ai_queries_per_day` and `conversation_window_minutes`, which metered
    # every MCP tool call in a 30-minute-window unit that corresponded to
    # nothing a user does. Their compound effect was a ~75 search and ~250
    # tool-call ceiling, neither of which appeared in any key.
    #
    # Burst and DoS defence is `EngramWeb.Plugs.PreAuthRateLimit` (600/min on
    # the shared pipeline), which is what the conversation meter was
    # approximating badly on a daily axis.
    ai_searches_per_day: %{type: :integer, defaults: %{free: 20, starter: nil, pro: nil}},
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
    # Gated in `Engram.Search.cross_vault_allowed/2`; the MCP transport bypasses
    # it deliberately (product decision 2026-07-10).
    cross_vault_search: %{type: :boolean, defaults: %{free: false, starter: false, pro: true}},
    # Connections caps — paid tiers unlimited. `obsidian_connections_cap` MUST
    # track `concurrent_devices` (see the note there): same underlying count,
    # two enforcement points.
    obsidian_connections_cap: %{type: :integer, defaults: %{free: 2, starter: nil, pro: nil}},
    # No MCP connection cap (#1974, removed). Every tier may hold any number of
    # MCP connections, OAuth grants and API keys alike: a connection costs
    # nothing, and use is metered by `ai_searches_per_day`. The cap only made
    # reconnecting a broken grant a 402. A leftover `mcp_connections_cap`
    # override row, plan key or env var is inert: every lookup is keyed by the
    # requested key, so nothing reads it.
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

  @doc """
  Which default set is enforced: `:v5` once the v5 go flag is on
  (`INDEX_BUDGET_ENABLED`, `Engram.Indexing.budget_enabled?/0`: the note caps
  are sized with the index points budget, `notes_cap` x 6), else `:legacy`.
  Every reader of a default goes through `default_for/2`, so the enforced
  caps, `/billing/usage`, capabilities and `/billing/config` never disagree.
  """
  @spec plan_limits() :: :v5 | :legacy
  def plan_limits, do: if(Engram.Indexing.budget_enabled?(), do: :v5, else: :legacy)

  @spec default_for(atom(), atom()) :: integer() | boolean() | String.t() | nil
  def default_for(key, tier), do: default_for(key, tier, plan_limits())

  @doc "`key`'s default for `tier` in one set; a key with one set answers it in both."
  @spec default_for(atom(), atom(), :v5 | :legacy) :: integer() | boolean() | String.t() | nil
  def default_for(key, tier, set) when key in @keys and tier in @tiers do
    entry = Map.fetch!(@catalog, key)

    defaults =
      if set == :v5, do: Map.get(entry, :v5_defaults, entry.defaults), else: entry.defaults

    Map.fetch!(defaults, tier)
  end

  # Renamed keys whose existing `user_limit_overrides` rows must keep working:
  # a row under the old name still applies to the new key (the new name wins
  # when both exist) and can still be edited. `lifetime_embed_token_cap` became
  # the refilling `embed_token_bucket`; a raised value or `-1` keeps its sense.
  @legacy_keys %{embed_token_bucket: "lifetime_embed_token_cap"}

  @doc "The old override key a renamed limit key still honours, or nil."
  @spec legacy_key(atom()) :: String.t() | nil
  def legacy_key(key), do: Map.get(@legacy_keys, key)

  @doc "True for an old override key name kept readable after a rename."
  @spec legacy_key?(term()) :: boolean()
  def legacy_key?(name), do: name in Map.values(@legacy_keys)

  @spec env_var_names() :: [{atom(), atom(), String.t()}]
  def env_var_names do
    for tier <- @tiers, key <- @keys do
      env =
        "ENGRAM_#{tier |> to_string() |> String.upcase()}_#{key |> to_string() |> String.upcase()}"

      {tier, key, env}
    end
  end
end
