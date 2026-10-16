defmodule Engram.Onboarding do
  @moduledoc """
  Onboarding context: TOS acceptance tracking and wizard-state computation.

  Onboarding runs for every account. The only toggle is `:billing_enabled`,
  which gates the hosted-only steps: agreement (ToS) and billing (Paddle).
  When false (self-host: AUTH_PROVIDER=local + no PADDLE_API_KEY), the wizard
  still runs but treats `terms_ok` and `subscription_ok` as auto-pass — the
  operator owns their own legal posture and there is no paywall. The `:vault`
  step (questionnaire + first vault) gates in every mode.
  """

  alias Engram.Accounts
  alias Engram.Cache
  alias Engram.Legal.VersionCache
  alias Engram.Logger.Metadata
  alias Engram.Onboarding.Action
  alias Engram.Onboarding.Agreement
  alias Engram.Onboarding.GateCache
  alias Engram.Repo
  alias Engram.Vaults

  require Logger

  # Origins `set_profile/2` records; "connector" is implied by `tools_prefilled`.
  @signup_sources ~w(plugin)

  @connector_vault_name "My Vault"
  @connector_vault_action "connector_vault_provisioned"
  @connector_vault_client_id "connector-signup"

  @terms_document "terms_of_service"
  @privacy_document "privacy_policy"

  # FTUX questionnaire tool catalog. Add new clients here in lockstep with
  # the frontend constants (see frontend/src/onboarding/onboarding-tools.ts).
  # Renames are MIGRATIONS — old slugs in user rows won't be auto-rewritten.
  #
  # No `gemini` entry on purpose: the consumer Gemini app cannot add a custom
  # remote MCP server (that is Gemini Enterprise / Antigravity only), so the row
  # would be uncompletable. Antigravity is Google's supported MCP path; it
  # superseded Gemini CLI for Pro/Ultra/free tiers on 2026-06-18. The frontend
  # lists a disabled `gemini` row to say so, and its absence here means that
  # slug can never reach a profile even if the UI is bypassed.
  @valid_tools ~w(
    claude chatgpt grok mistral open_webui lobechat muse
    claude_code cursor devin windsurf cline continue opencode github_copilot antigravity
    web_only other_mcp
  )

  @doc """
  Returns the canonical list of valid tool slugs accepted by `set_profile/2`.
  """
  def valid_tools, do: @valid_tools

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
    # Read before the insert: only a first acceptance starts the account on
    # Free (`after_terms/2`); re-accepting changed terms is not a plan choice.
    first_acceptance = is_nil(accepted_version(user, @terms_document))
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
    result =
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

    case result do
      {:ok, tos_row} ->
        # Evict, not put: a peer node may hold the old version, and a put
        # could land over a newer one a concurrent read just stored.
        :ok = Cache.evict(:terms, {user.id, @terms_document})
        :ok = Cache.evict(:terms, {user.id, @privacy_document})
        :ok = after_terms(user, first_acceptance)
        {:ok, tos_row}

      other ->
        other
    end
  end

  @doc """
  Record that `user` accepted Terms of Service version `version` (no content
  hash, no Privacy row). Retained for the existing controller/tests until the
  controller is migrated to the 6-arity form. Delegates to `insert_agreement/1`.
  """
  def accept_terms(user, version, meta) when is_binary(version) do
    result =
      insert_agreement(%{
        user_id: user.id,
        document: @terms_document,
        version: version,
        accepted_at: DateTime.utc_now(:second),
        ip_address: Map.get(meta, :ip_address),
        user_agent: Map.get(meta, :user_agent)
      })

    with {:ok, _} <- result, do: :ok = Cache.evict(:terms, {user.id, @terms_document})
    result
  end

  # Upsert on (user_id, document, version) so re-accepts of the same version
  # refresh the audit fields instead of inserting duplicate rows. Unique
  # index `user_agreements_user_document_version_unique` enforces this at DB.
  defp insert_agreement(attrs) do
    # Inside with_tenant, not `skip_tenant_check: true` alone (#1354, same as
    # `record_action/2`). `user_agreements` carries FORCE ROW LEVEL SECURITY,
    # so with no `app.current_tenant` the policy's WITH CHECK fails and this
    # INSERT RAISES 42501 — `skip_tenant_check` only silences Engram's own
    # guard, it does not set the tenant.
    #
    # Observed on staging the moment the app pool dropped to `engram_app`:
    # POST /api/onboarding/accept-terms 500'd for EVERY user, blocking new
    # signups and re-acceptance alike.
    #
    # `accept_terms/6` calls this twice inside one `Repo.transaction`, and each
    # call is independently scoped: `run_with_tenant/2` deletes the process-dict
    # tenant in its `after` block, so the second call re-enters and issues its
    # own `set_config` round trip. The re-entrant fast path needs an enclosing
    # `with_tenant`, which a plain transaction is not. The transaction still
    # does its job — the two rows are atomic.
    {:ok, result} =
      Repo.with_tenant(attrs.user_id, fn ->
        %Agreement{}
        |> Agreement.changeset(attrs)
        |> Repo.insert(
          on_conflict: {:replace, [:accepted_at, :ip_address, :user_agent, :content_hash]},
          conflict_target: [:user_id, :document, :version],
          returning: true
        )
      end)

    result
  end

  @doc """
  Compute the onboarding state for a user. Returns a map with:

    * `:enabled` — true when billing (and therefore the wizard) is active
    * `:terms_ok` — the user's accepted ToS and Privacy versions satisfy each
      document's computed floor
    * `:subscription_ok` — user has trialing/active/past_due subscription
    * `:current_tos_version` — latest published ToS version (from `terms_versions`)
    * `:current_privacy_version` — latest published Privacy version
    * `:legal_notices`: pending legal changes, see `legal_notices/1`
    * `:next_step` — one of `:agreement | :billing | :vault | :done`

  The gate is computed from the `terms_versions` table via
  `Engram.Legal.VersionCache`: `terms_ok` compares the user's latest accepted
  version against the required floor (latest MATERIAL version effective now).

  When `billing_enabled` is false (self-host), agreement + billing steps
  short-circuit to ok and the chain falls through to vault, which owns the
  obsidian/fresh source pick + first-vault creation. Tools and use cases are
  collected after first value by the in-app survey, not by the wizard.
  `:enabled` is always true — every account onboards.
  """
  def status(user) do
    billing_active = Application.get_env(:engram, :billing_enabled, false)

    {terms_ok, current_tos, current_privacy} = terms_state(user, billing_active)

    # Under the Free-tier model: paid tiers (:starter / :pro) pass on tier alone;
    # Free users must EXPLICITLY accept the Free tier via the onboarding wizard
    # (`free_tier_accepted_at` set). Self-host (`billing_enabled=false`)
    # auto-passes without consulting the resolver. Reuses `billing_active`
    # from above — this used to re-read the config key with the OPPOSITE
    # default (true vs false), so an unset key produced self-host wizard
    # steps but SaaS subscription gating in the same response.
    subscription_ok =
      not billing_active or
        Engram.Billing.tier(user) in [:starter, :pro] or
        not is_nil(user.free_tier_accepted_at)

    # The cached users row, not a fresh read: set_profile/2 evicts the :user
    # cache after commit, so this sees the saved profile even when the caller
    # holds a struct from before the save.
    profile = current_profile(user)
    profile_complete = profile_complete?(profile)
    has_vault = Vaults.has_vault?(user)

    next =
      next_step(terms_ok, subscription_ok, profile_complete, profile, has_vault)

    steps =
      build_steps(billing_active, profile, %{
        profile_complete: profile_complete,
        has_vault: has_vault,
        terms_ok: terms_ok,
        subscription_ok: subscription_ok
      })

    base = %{
      enabled: true,
      terms_ok: terms_ok,
      subscription_ok: subscription_ok,
      profile_complete: profile_complete,
      profile: profile,
      has_vault: has_vault,
      current_tos_version: current_tos,
      current_privacy_version: current_privacy,
      legal_notices: legal_notices(user),
      next_step: next,
      steps: steps
    }

    # The authoritative runtime verdict, derived by the SAME function `gate/2`
    # enforces with, so a caller can ask "may this user proceed" without
    # reimplementing the rules.
    #
    # It is NOT `next_step == :done`. Wizard navigation and runtime permission
    # are deliberately decoupled (see `next_step/5`): an obsidian-path user
    # sits at `:vault` until the plugin first-syncs, while the gate already
    # admits them. Anything that re-derives the verdict from `next_step` gets
    # that case backwards — the consent page did, and bounced those users
    # between consent and the wizard forever.
    Map.put(base, :gate_ok, gate_missing(base) == [])
  end

  @doc """
  Authoritative runtime-traffic gate: may `user` reach vault data paths?

  Returns `:ok`, or `{:error, missing, next_step}` where `missing` is the
  sorted list of unmet requirements (`"terms"`, `"subscription"`, `"profile"`,
  `"vault"`).

  Both enforcement points route through here — `EngramWeb.Plugs.RequireOnboarding`
  (HTTP) and the `sync:` / `crdt:` channel joins (WebSocket). Sync lives on
  Phoenix Channels and a Plug never runs on a socket, so this rule cannot live
  in the router pipeline alone: it did, and an account that skipped ToS and
  plan selection synced a whole vault over the socket while every REST route
  correctly 403'd it.

  PASS verdicts are cached per node (`Engram.Onboarding.GateCache`); failing
  users always take the authoritative slow path.
  """
  @spec gate(Engram.Accounts.User.t(), keyword()) :: :ok | {:error, [String.t()], atom()}
  def gate(%{id: user_id} = user, opts \\ []) do
    GateCache.verdict(user_id, fn ->
      # Re-read the row. `status/1` derives `subscription_ok` partly from
      # `user.free_tier_accepted_at` on the STRUCT, while every other input
      # (terms, profile, vault, subscription row) is queried fresh. That was
      # harmless when the only caller was a Plug — `Plugs.Auth` reloads the
      # user per request. `UserSocket` assigns `current_user` ONCE at
      # `connect/3`, so a Free user who clicks "Continue with Free" mid-session
      # would re-derive from a stale struct on every rejoin and stay locked out
      # for the life of the connection. `accept_free_tier/1` is a bare
      # `Repo.update` with no socket disconnect, so nothing else would clear it.
      # `fresh: true` means the caller already re-read this row this join
      # (see `EngramWeb.ChannelGate.check/3`) — don't pay for it twice.
      user =
        if Keyword.get(opts, :fresh, false),
          do: user,
          else: Accounts.get_user(user_id) || user

      # A purged row (`Accounts.Lifecycle.hard_delete/2`) leaves the `|| user`
      # fallback above holding a struct that predates the deletion. Callers on
      # the socket side go through `EngramWeb.ChannelGate`, which refuses
      # outright before reaching here; this is the belt for any HTTP caller,
      # where `Plugs.Auth` has already 401'd a missing user in practice.
      derive_gate(user, status(user), opts)
    end)
  end

  # `:pass` is cached by GateCache.verdict/2; `:ok` is a pass it must not cache.
  defp derive_gate(_user, %{next_step: :done}, _opts), do: :pass

  defp derive_gate(user, status, opts) do
    %{next_step: next_step} = status
    missing = gate_missing(status)

    cond do
      missing == [] ->
        # All enforced gates pass even though wizard navigation isn't `:done`
        # yet (e.g. obsidian user mid-flow whose plugin is about to first-sync).
        # Runtime traffic permission and wizard state are intentionally
        # decoupled — see `next_step/5`.
        :pass

      # Deliberately NOT cached. The cache is shared with the channel joins,
      # which enforce the strict rule — writing a relaxed PASS here would hand
      # the full sync path to a user `gate/1` rejects.
      missing == ["vault"] and Keyword.get(opts, :skip_vault, false) ->
        :ok

      true ->
        # Emitted HERE rather than in `RequireOnboarding`, because both
        # transports funnel through this function — HTTP via the plug,
        # sockets via `ChannelGate` — so one line covers both.
        #
        # Category `:lifecycle`, NOT `:auth`. The `auth-failure-burst` alert
        # counts `metadata_category="auth"` at warning-or-above to catch
        # credential stuffing. An onboarding refusal presents no credentials,
        # so filing it there would pad a security signal with traffic that is
        # not a security event — a retry loop like #1666 (twelve attempts over
        # five hours) is well inside that rule's threshold, so it would not
        # fire it, just quietly make its baseline dishonest.
        # `:warning` also guarantees the line reaches Loki
        # (`Category.loki_ship?/2` is true for warning and above) without
        # tripping `error-rate`, which matches error severity and up.
        #
        # One line per refused request: failing verdicts are never cached
        # (`GateCache` holds passes only), which is what makes a burst
        # countable. A user stuck in a retry loop is exactly the shape this
        # exists to surface — #1666 ran for five hours with no signal at all.
        Logger.warning(
          "onboarding refused",
          Metadata.with_category(:warning, :lifecycle,
            reason: "onboarding_required",
            missing: Enum.join(missing, ","),
            next_step: to_string(next_step),
            user_id: user.id
          )
        )

        {:error, missing, next_step}
    end
  end

  # The sorted list of unmet runtime requirements, or `[]` when the user may
  # proceed. Single source of truth: `gate/2` enforces with it and `status/1`
  # publishes its emptiness as `:gate_ok`, so the wire answer and the enforced
  # answer cannot drift.
  #
  # Every key is destructured, none defaulted. `has_vault` and `profile` used
  # to come from `Map.get/3` with fail-OPEN defaults three lines under four
  # strictly-matched siblings: dropping `:next_step` from `status/1` would
  # raise, while dropping `:has_vault` would silently pass the vault rule for
  # every user on both transports, with no compile error and no test failure.
  defp gate_missing(%{
         terms_ok: terms_ok,
         subscription_ok: sub_ok,
         profile_complete: profile_ok,
         has_vault: has_vault,
         profile: profile
       }) do
    profile = profile || %{}
    # uses_obsidian users bypass the vault gate (the plugin creates the vault).
    vault_required = profile_ok and Map.get(profile, "uses_obsidian") != true

    []
    |> then(&if terms_ok, do: &1, else: ["terms" | &1])
    |> then(&if sub_ok, do: &1, else: ["subscription" | &1])
    |> then(&if profile_ok, do: &1, else: ["profile" | &1])
    |> then(&if not vault_required or has_vault, do: &1, else: ["vault" | &1])
    |> Enum.sort()
  end

  # Enumerates the step chain so the frontend can render "Step X of N"
  # without re-deriving the gate rules: the terms, then the vault step for a
  # web signup. Every account starts on Free when it accepts the terms
  # (`after_terms/1`), so the plan step is gone; tools and the survey moved
  # into the app.
  #
  # A step must stay listed whenever `next_step/5` can still return it, or the
  # wizard is pointed at a step the chain does not list and loops:
  #
  #   * `:billing` when terms pass without a plan (accepted before the Free
  #     start existed, or the stamp failed).
  #   * `:vault` unless the signup's origin already settled it: a plugin-first
  #     profile that completed, or a connector profile that completed and
  #     either has its vault or has not reached the plan yet. A connector
  #     whose provisioning failed, or that deleted the vault, keeps it.
  defp build_steps(billing_active, profile, %{} = state) do
    plan_ok = state.terms_ok and state.subscription_ok
    stuck_on_billing = state.terms_ok and not state.subscription_ok

    vault_settled =
      state.profile_complete and
        (plugin_source?(profile) or
           (tools_prefilled?(profile) and (state.has_vault or not plan_ok)))

    agreement = if billing_active, do: [:agreement], else: []
    billing = if billing_active and stuck_on_billing, do: [:billing], else: []
    vault = if vault_settled, do: [], else: [:vault]

    agreement ++ billing ++ vault
  end

  # Where the signup started, as recorded on its profile. A connector signup
  # is marked by its OAuth client pre-answering `tools`; a plugin-first one by
  # /link (`signup_source: "plugin"`). Anything else started on the web.
  #
  # A plugin-first signup skips the vault wait only while it still uses
  # Obsidian: that is what lets `gate_missing/1` admit it without a vault. One
  # that answered "fresh" needs a vault like anyone else, or `next_step` would
  # say :done while the gate refuses (and `gate/2` caches the :done as a pass).
  defp plugin_source?(%{"signup_source" => "plugin", "uses_obsidian" => true}), do: true
  defp plugin_source?(_), do: false

  defp tools_prefilled?(%{"tools_prefilled" => true}), do: true
  defp tools_prefilled?(_), do: false

  # Self-host (billing_enabled=false) doesn't run a ToS gate — operators own
  # their legal posture. Hosted mode performs the real cache-backed check.
  defp terms_state(_user, false), do: {true, nil, nil}

  defp terms_state(user, true) do
    current_tos = VersionCache.current_version(@terms_document)
    current_privacy = VersionCache.current_version(@privacy_document)
    terms_ok = Enum.all?([@terms_document, @privacy_document], &meets_floor?(user, &1))
    {terms_ok, current_tos, current_privacy}
  end

  # No floor, no acceptance read: privacy has none until a material change is
  # announced (`Engram.Legal.required_floor/2`).
  defp meets_floor?(user, document) do
    case VersionCache.required_floor(document) do
      nil -> true
      floor -> accepted_satisfies?(accepted_version(user, document), floor)
    end
  end

  @doc """
  Announced legal changes `user` has not accepted: at most one per document
  (ToS first), as `document/version/effective_date/material/changelog/url/
  accept_url`. Announced means it has an effective_date; a version without one
  is a silent wording fix and never hides an announced change behind it.

  A notice-only change is listed until its effective date, then simply
  applies. A material change stays listed after its date too, because that is
  when `terms_ok` fails and the agreement page must show what changed. When
  several are pending, the material one wins, then the earliest date.

  The same list feeds the web banner, the agreement page, the plugin and MCP
  tool results. Empty on self-host. Cached reads only; the acceptance read runs
  only when an announced change exists.
  """
  @spec legal_notices(map()) :: [map()]
  def legal_notices(user) do
    if Application.get_env(:engram, :billing_enabled, false) do
      today = Date.utc_today()

      Enum.flat_map([@terms_document, @privacy_document], &pending_notice(user, &1, today))
    else
      []
    end
  end

  defp pending_notice(user, document, today) do
    case Enum.filter(VersionCache.versions(document), &open?(&1, today)) do
      [] ->
        []

      open ->
        accepted = accepted_version(user, document)

        open
        |> Enum.filter(&(is_nil(accepted) or &1.version > accepted))
        |> Enum.sort_by(&{not &1.material, Date.to_iso8601(&1.effective_date)})
        |> Enum.take(1)
        |> Enum.map(&notice_map/1)
    end
  end

  defp open?(%{effective_date: nil}, _today), do: false
  defp open?(%{material: true}, _today), do: true
  defp open?(%{effective_date: date}, today), do: Date.after?(date, today)

  @doc "Whether `user` has accepted `version` of `document` (or a later one)."
  @spec accepted?(map(), String.t(), String.t()) :: boolean()
  def accepted?(user, document, version) do
    case accepted_version(user, document) do
      nil -> false
      accepted -> accepted >= version
    end
  end

  defp notice_map(row) do
    %{
      document: row.document,
      version: row.version,
      effective_date: row.effective_date,
      material: row.material,
      changelog: row.changelog,
      url: Engram.Legal.url(row.document),
      accept_url: Engram.Legal.accept_url()
    }
  end

  @doc """
  Merge partial onboarding answers into `user.onboarding_profile`. Callers
  POST what they know: `uses_obsidian` from `/onboard/vault` (or /link),
  `signup_source` from /link, `tools` + `tools_prefilled` from an OAuth
  consent pre-answer, `tools` from the in-app survey. `completed_at` stamps
  once the Obsidian question is answered, or the profile was pre-filled by a
  connector; that is the signal `profile_complete?/1` keys on.

  Validates only the fields actually being set: `tools` must be a non-empty
  list of slugs from `valid_tools/0`; `uses_obsidian` and `tools_prefilled`
  must be booleans; `signup_source` must be a known origin. Empty payloads are
  rejected so a stray POST can't no-op-succeed.

  Returns `{:ok, %User{}}` or `{:error, atom}` where atom is one of
  `:invalid_uses_obsidian | :empty_tools | :invalid_tool |
  :invalid_tools_prefilled | :invalid_signup_source | :nothing_to_set`.
  """
  def set_profile(user, attrs) when is_map(attrs) do
    with :ok <- validate_profile_attrs(attrs) do
      existing = fresh_profile(user) || %{}

      merged =
        existing
        |> maybe_put_field(attrs, :tools, "tools")
        |> maybe_put_field(attrs, :tools_prefilled, "tools_prefilled")
        |> maybe_put_field(attrs, :uses_obsidian, "uses_obsidian")
        |> maybe_put_field(attrs, :signup_source, "signup_source")
        |> maybe_stamp_completed_at()

      user
      |> Ecto.Changeset.change(onboarding_profile: merged)
      |> Repo.update(skip_tenant_check: true)
      |> tap(fn
        # uses_obsidian flips can re-arm the vault gate for a passed
        # user — drop the cached verdict so the plug re-derives.
        {:ok, _} ->
          Engram.Onboarding.GateCache.evict(user.id)
          evict_user(user.id)

        _ ->
          :ok
      end)
      |> tap(fn
        # Only the pre-answer itself, never a later save of the merged
        # profile: the vault page's `uses_obsidian` POST would otherwise mint
        # a vault for someone who chose Obsidian, or one the Free cap then
        # refuses the page's own create over.
        {:ok, saved} ->
          if attrs[:tools_prefilled] == true, do: maybe_provision_connector_vault(saved)

        _ ->
          :ok
      end)
      |> tap(fn
        {:ok, saved} -> track_signup_source(saved, attrs, existing)
        _ -> :ok
      end)
    end
  end

  defp validate_profile_attrs(attrs) do
    has_tools = Map.has_key?(attrs, :tools)
    has_source = Map.has_key?(attrs, :uses_obsidian)
    has_prefilled = Map.has_key?(attrs, :tools_prefilled)
    has_signup_source = Map.has_key?(attrs, :signup_source)

    cond do
      not has_tools and not has_source and not has_prefilled and not has_signup_source ->
        {:error, :nothing_to_set}

      has_signup_source and Map.get(attrs, :signup_source) not in @signup_sources ->
        {:error, :invalid_signup_source}

      # A qualifier on `tools`, never a standalone fact. Accepting it alone
      # would let a stray POST turn an ordinary signup into a connector one:
      # vault provisioned, vault step dropped from the chain.
      has_prefilled and not has_tools ->
        {:error, :nothing_to_set}

      has_prefilled and not is_boolean(Map.get(attrs, :tools_prefilled)) ->
        {:error, :invalid_tools_prefilled}

      has_tools and not is_list(Map.get(attrs, :tools)) ->
        {:error, :empty_tools}

      has_tools and Map.get(attrs, :tools) == [] ->
        {:error, :empty_tools}

      has_tools and Enum.any?(Map.get(attrs, :tools), &(&1 not in @valid_tools)) ->
        {:error, :invalid_tool}

      has_source and not is_boolean(Map.get(attrs, :uses_obsidian)) ->
        {:error, :invalid_uses_obsidian}

      true ->
        :ok
    end
  end

  @doc """
  Creates the default vault for a connector signup (see `build_steps/3`) once
  it is due: the profile was pre-filled by an OAuth client, the Obsidian
  question was never answered, there is no vault yet, and terms and plan both
  pass. Nothing is created before the user has accepted the terms.

  Called where those last two flip: `set_profile/2` (the pre-answer, for an
  account already past them, and self-host, which has neither),
  `accept_terms/6` (terms re-accepted after the plan), `accept_free_tier/1`,
  and `subscription.created` in `Engram.Billing`.
  Idempotent: keyed on a fixed client_id, and a no-op when not due.

  Best-effort: a failure only means `build_steps/3` keeps `:vault` in the
  chain, which is the ordinary signup flow. Logged so that fallback is visible.
  """
  @spec maybe_provision_connector_vault(Engram.Accounts.User.t()) :: :ok
  def maybe_provision_connector_vault(user) do
    user = Accounts.get_user(user.id) || user
    status = status(user)
    profile = status.profile || %{}

    # `profile_complete`: a connector row pre-filled before connector profiles
    # completed at the pre-answer is still on the vault step, where a minted
    # "My Vault" would make the Free cap refuse the vault the user creates.
    # Provisioned once ever: a vault the user deleted stays deleted.
    due =
      tools_prefilled?(profile) and status.profile_complete and
        not is_boolean(profile["uses_obsidian"]) and not status.has_vault and
        status.terms_ok and status.subscription_ok and
        @connector_vault_action not in list_actions(user.id)

    if due, do: provision_connector_vault(user), else: :ok
  rescue
    # Never raises: one caller is a Paddle webhook, where an escaping error is
    # answered 200 anyway and never retried. The fallback is the vault step.
    error ->
      Logger.error(
        "connector vault provisioning raised",
        Metadata.with_category(:error, :lifecycle,
          user_id: user.id,
          reason: Metadata.safe_reason(error)
        )
      )

      :ok
  end

  # Every signup starts on Free when it first accepts the terms, so there is
  # no plan step: get people using it first, upgrade prompts later. Only at the
  # first acceptance, and only when no plan passes yet: a paid account keeps
  # its plan, and a lapsed one re-accepting changed terms stays at the plan
  # step. Then a connector signup's vault, which is due once terms and plan
  # both pass. A failed stamp leaves `:billing` in the chain
  # (`build_steps/3`), the old flow.
  defp after_terms(user, first_acceptance) do
    user = Accounts.get_user(user.id) || user

    starts_free =
      first_acceptance and Application.get_env(:engram, :billing_enabled, false) and
        is_nil(user.free_tier_accepted_at) and
        Engram.Billing.tier(user) not in [:starter, :pro]

    if starts_free do
      case accept_free_tier(user) do
        # accept_free_tier/1 provisions the vault itself.
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "free start failed",
            Metadata.with_category(:warning, :lifecycle,
              user_id: user.id,
              reason: Metadata.safe_reason(reason)
            )
          )

          :ok
      end
    else
      maybe_provision_connector_vault(user)
    end
  end

  defp provision_connector_vault(user) do
    case Vaults.register_vault(user, @connector_vault_name, @connector_vault_client_id) do
      {:ok, vault, :created} ->
        # The DEK is minted inside register_vault, after `user` was read; the
        # seed needs it on the struct (same as `VaultsController.register`).
        user =
          case Engram.Crypto.ensure_user_dek(user) do
            {:ok, user} -> user
            _ -> user
          end

        Vaults.WelcomeNote.seed(user, vault)
        _ = record_action(user.id, @connector_vault_action)

      {:ok, _vault, :existing} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "connector vault provisioning failed",
          Metadata.with_category(:warning, :lifecycle,
            user_id: user.id,
            reason: Metadata.safe_reason(reason)
          )
        )
    end

    :ok
  end

  # Plugin and connector signups are not asked how they heard about us: where
  # they started is the answer, recorded once so funnels can break down by it.
  # Once: a plugin-first user who later connects ChatGPT through a consent
  # screen still started on the plugin. Skipped when the profile already had an
  # origin, and `$set_once` so PostHog keeps the first one regardless.
  defp track_signup_source(_user, _attrs, %{"signup_source" => _}), do: :ok
  defp track_signup_source(_user, _attrs, %{"tools_prefilled" => true}), do: :ok

  defp track_signup_source(user, %{signup_source: "plugin"}, _existing),
    do: send_signup_source(user, "plugin", "obsidian")

  defp track_signup_source(user, %{tools_prefilled: true, tools: [tool | _]}, _existing),
    do: send_signup_source(user, "connector", tool)

  defp track_signup_source(_user, _attrs, _existing), do: :ok

  defp send_signup_source(user, source, tool) do
    Engram.Analytics.track(user, "signup_source_recorded", %{
      "signup_source" => source,
      "signup_tool" => tool,
      "$set_once" => %{"signup_source" => source, "signup_tool" => tool}
    })
  end

  defp maybe_put_field(profile, attrs, key, json_key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> Map.put(profile, json_key, value)
      :error -> profile
    end
  end

  # Stamp once, when BOTH halves of the questionnaire have landed. Stamping
  # is one-shot: a re-POST that overwrites one field doesn't refresh the
  # timestamp, so `profile_complete?` reads as a monotonic latch.
  defp maybe_stamp_completed_at(profile) do
    # The Obsidian question is the only one the wizard asks. A connector
    # signup is never asked it: the client it came from is its answer, and the
    # plugin answers it later if they link. Tools are asked in the app.
    has_source = is_boolean(Map.get(profile, "uses_obsidian")) or tools_prefilled?(profile)
    has_stamp = is_binary(Map.get(profile, "completed_at"))

    if has_source and not has_stamp do
      Map.put(profile, "completed_at", DateTime.utc_now(:second) |> DateTime.to_iso8601())
    else
      profile
    end
  end

  # The read-modify-write in set_profile/2 merges into the DB's row, not a
  # cached one another node may have outdated.
  defp fresh_profile(user) do
    import Ecto.Query

    from(u in Engram.Accounts.User,
      where: u.id == ^user.id,
      select: u.onboarding_profile
    )
    |> Repo.one(skip_tenant_check: true)
  end

  # The cached row, not the caller's struct: callers that just ran
  # `set_profile/2` and then `status/1` would otherwise see a stale `nil` and
  # the gate would stick on `:vault` even after a successful save.
  defp current_profile(user) do
    case Engram.Accounts.get_user(user.id) do
      %{onboarding_profile: profile} -> profile
      nil -> nil
    end
  end

  defp profile_complete?(%{"completed_at" => ts}) when is_binary(ts), do: true
  defp profile_complete?(_), do: false

  # Cache-first read of the user's latest accepted version for a document.
  # Through fetch/3, so an accept's eviction that lands mid-read wins.
  defp accepted_version(user, document) do
    Cache.fetch(:terms, {user.id, document}, fn -> query_accepted_version(user, document) end)
  end

  defp accepted_satisfies?(nil, _floor), do: false
  defp accepted_satisfies?(accepted, floor), do: accepted >= floor

  defp query_accepted_version(user, document) do
    import Ecto.Query

    # Inside with_tenant (#1354, same as `list_actions/1`). `user_agreements`
    # carries FORCE ROW LEVEL SECURITY, so the unscoped form returns nil for a
    # user who HAS accepted — a filtered read, not an error. `terms_ok` then
    # reads false and the wizard sends an already-onboarded user back to
    # /onboard/agreement, where the accept POST also fails. Dead end both ways.
    #
    # Verified on staging: a user with terms_of_service + privacy_policy rows
    # dated 2026-06-15 still got terms_ok=false.
    {:ok, version} =
      Repo.with_tenant(user.id, fn ->
        from(a in Agreement,
          where: a.user_id == ^user.id and a.document == ^document,
          # Highest version, not newest row: two accepts in one second tie on
          # accepted_at (second precision). Versions sort as dates.
          order_by: [desc: a.version],
          limit: 1,
          select: a.version
        )
        |> Repo.one()
      end)

    version
  end

  defp next_step(false, _, _, _, _), do: :agreement
  defp next_step(true, false, _, _, _), do: :billing

  # The wizard asks one question beyond the terms: Obsidian or fresh, on the
  # vault step. Tools and the user-voice survey are asked in the app after
  # first value, never here. Plugin and connector signups answered the
  # question by where they started (`set_profile/2`).
  defp next_step(true, true, false, _profile, _has_vault), do: :vault

  # Wizard navigation requires an actual vault row, except for a plugin-first
  # signup: its plugin creates the vault on first sync, which cannot happen
  # until the parked /link code is authorized, so the wizard hands back to
  # /link instead of waiting. A web signup that picked Obsidian waits here for
  # that first sync. The gate admits both earlier (`gate_missing/1`), so the
  # plugin can push. See `EngramWeb.Plugs.RequireOnboarding`.
  defp next_step(true, true, true, profile, has_vault) do
    if has_vault or plugin_source?(profile), do: :done, else: :vault
  end

  @doc """
  Mark the user as having chosen the Free tier during onboarding. Idempotent:
  if `free_tier_accepted_at` is already set, returns the user unchanged.
  """
  @spec accept_free_tier(Engram.Accounts.User.t()) ::
          {:ok, Engram.Accounts.User.t()} | {:error, Ecto.Changeset.t()}
  def accept_free_tier(%{free_tier_accepted_at: %DateTime{}} = user), do: {:ok, user}

  def accept_free_tier(%Engram.Accounts.User{} = user) do
    user
    |> Ecto.Changeset.change(free_tier_accepted_at: DateTime.utc_now())
    |> Repo.update()
    |> tap(fn
      {:ok, saved} ->
        evict_user(user.id)
        maybe_provision_connector_vault(saved)

      _ ->
        :ok
    end)
  end

  # The wizard's very next request (or socket rejoin) reads the cached user and
  # must see the step it just completed. The users trigger evicts every node on
  # commit, but its NOTIFY lands asynchronously; this makes the writing node
  # coherent before the response goes out.
  defp evict_user(user_id), do: Accounts.evict_user(user_id)

  @doc """
  Record an onboarding milestone for `user_id`. Idempotent — re-recording the
  same action returns `:ok` with no extra row. Returns `{:error, changeset}`
  only on enum/validation failure.
  """
  def record_action(user_id, action) when is_atom(action) do
    record_action(user_id, Atom.to_string(action))
  end

  def record_action(user_id, action) when is_binary(user_id) and is_binary(action) do
    # Inside with_tenant, not `skip_tenant_check: true` alone (#1354).
    # `onboarding_actions` carries FORCE ROW LEVEL SECURITY and prod's role
    # (`engram_admin`, verified rolbypassrls=false) is bound by it even as the
    # table owner, so with no `app.current_tenant` the policy's WITH CHECK
    # fails and this INSERT RAISES on prod. skip_tenant_check only silences
    # Engram's own guard; it does not set the tenant.
    Repo.with_tenant(user_id, fn ->
      %Action{}
      |> Action.changeset(%{user_id: user_id, action: action})
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :action])
      |> case do
        {:ok, _} -> evict_actions(user_id)
        {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Return the set of onboarding actions recorded for `user_id` as a list of
  string action names. Empty list for unknown user.
  """
  def list_actions(user_id) when is_binary(user_id) do
    import Ecto.Query

    # Inside with_tenant (#1354): the unscoped form returned [] for EVERY user
    # on prod under FORCE RLS, so the onboarding wizard showed nobody's
    # completed steps. Locally it looked fine — dev/CI connect as a superuser,
    # which bypasses RLS regardless of FORCE. Cached per owner (:onboarding_actions).
    Engram.Cache.fetch(:onboarding_actions, user_id, fn ->
      Repo.with_tenant!(user_id, fn ->
        from(a in Action, where: a.user_id == ^user_id, select: a.action)
        |> Repo.all()
      end)
    end)
  end

  @doc false
  # After commit (Engram.Cache.evict/2 waits for it), on every node.
  @spec evict_actions(Ecto.UUID.t()) :: :ok
  def evict_actions(user_id), do: Engram.Cache.evict(:onboarding_actions, user_id)
end
