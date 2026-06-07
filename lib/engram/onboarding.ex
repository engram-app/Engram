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

  alias Engram.Billing
  alias Engram.Legal
  alias Engram.Legal.VersionCache
  alias Engram.Onboarding.Action
  alias Engram.Onboarding.Agreement
  alias Engram.Onboarding.TermsCache
  alias Engram.Repo
  alias Engram.Vaults

  @terms_document "terms_of_service"
  @privacy_document "privacy_policy"

  # FTUX questionnaire tool catalog. Add new clients here in lockstep with
  # the frontend constants (see frontend/src/onboarding/onboarding-tools.ts).
  # Renames are MIGRATIONS — old slugs in user rows won't be auto-rewritten.
  @valid_tools ~w(
    claude chatgpt grok mistral open_webui lobechat
    claude_code cursor windsurf cline continue opencode github_copilot
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
        TermsCache.put_accepted(user.id, @terms_document, tos_version)
        TermsCache.put_accepted(user.id, @privacy_document, privacy_version)
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
    insert_agreement(%{
      user_id: user.id,
      document: @terms_document,
      version: version,
      accepted_at: DateTime.utc_now(:second),
      ip_address: Map.get(meta, :ip_address),
      user_agent: Map.get(meta, :user_agent)
    })
  end

  # Upsert on (user_id, document, version) so re-accepts of the same version
  # refresh the audit fields instead of inserting duplicate rows. Unique
  # index `user_agreements_user_document_version_unique` enforces this at DB.
  defp insert_agreement(attrs) do
    %Agreement{}
    |> Agreement.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:accepted_at, :ip_address, :user_agent, :content_hash]},
      conflict_target: [:user_id, :document, :version],
      returning: true,
      skip_tenant_check: true
    )
  end

  @doc """
  Compute the onboarding state for a user. Returns a map with:

    * `:enabled` — true when billing (and therefore the wizard) is active
    * `:terms_ok` — latest accepted ToS version satisfies the computed floor
    * `:subscription_ok` — user has trialing/active/past_due subscription
    * `:current_tos_version` — latest published ToS version (from `terms_versions`)
    * `:current_privacy_version` — latest published Privacy version
    * `:terms_notice` — metadata for the newest published ToS version the user
      has not yet accepted (version/effective_date/material/changelog/accept_url),
      or `nil` when the user is already on the current version
    * `:next_step` — one of `:agreement | :billing | :tools | :vault | :done`

  The gate is computed from the `terms_versions` table via
  `Engram.Legal.VersionCache`: `terms_ok` compares the user's latest accepted
  version against the required floor (latest MATERIAL version effective now).

  `:terms_notice` is independent of `:terms_ok`: it carries the pending version's
  metadata whenever a newer published version exists unaccepted, and is the same
  payload the client renders both as the non-blocking notice (while `terms_ok`
  is still true, before the version's `effective_date`) and as the accept prompt
  once the version is effective and `terms_ok` has flipped false.

  When `billing_enabled` is false (self-host), agreement + billing steps
  short-circuit to ok and the chain falls through to tools → vault. The
  `:tools` step collects the questionnaire's tool checkboxes; `:vault`
  owns the obsidian/fresh source pick + first-vault creation.
  `:enabled` is always true — every account onboards.
  """
  def status(user) do
    billing_active = Application.get_env(:engram, :billing_enabled, false)

    {terms_ok, current_tos, current_privacy, terms_notice} =
      terms_state(user, billing_active)

    subscription_ok = if billing_active, do: Billing.active?(user), else: true
    profile = current_profile(user)
    profile_complete = profile_complete?(profile)
    has_vault = Vaults.has_vault?(user)
    next = next_step(terms_ok, subscription_ok, profile_complete, profile, has_vault)
    steps = build_steps(billing_active, profile)

    %{
      enabled: true,
      terms_ok: terms_ok,
      subscription_ok: subscription_ok,
      profile_complete: profile_complete,
      profile: profile,
      has_vault: has_vault,
      current_tos_version: current_tos,
      current_privacy_version: current_privacy,
      terms_notice: terms_notice,
      next_step: next,
      steps: steps
    }
  end

  # Enumerates the full step chain so the frontend can render "Step X of N"
  # without re-deriving the gate rules. `:tools` collects the questionnaire's
  # tool picks; `:vault` collects the obsidian/fresh source pick and creates
  # (or waits on) the first vault.
  defp build_steps(billing_active, _profile) do
    if billing_active, do: [:agreement, :billing, :tools, :vault], else: [:tools, :vault]
  end

  # Self-host (billing_enabled=false) doesn't run a ToS gate — operators own
  # their legal posture. Hosted mode performs the real cache-backed check.
  defp terms_state(_user, false), do: {true, nil, nil, nil}

  defp terms_state(user, true) do
    floor = VersionCache.required_floor(@terms_document)
    current_tos = VersionCache.current_version(@terms_document)
    current_privacy = VersionCache.current_version(@privacy_document)
    accepted_tos = accepted_version(user, @terms_document)
    terms_ok = accepted_satisfies?(accepted_tos, floor)
    {terms_ok, current_tos, current_privacy, notice(@terms_document, current_tos, accepted_tos)}
  end

  @doc """
  Merge partial FTUX answers into `user.onboarding_profile`. The wizard
  POSTs once per screen (tools from `/onboard/tools`, uses_obsidian from
  `/onboard/vault`), so this accepts either field independently or both
  together. `completed_at` stamps the moment BOTH `tools` and
  `uses_obsidian` are present after the merge — that's the signal
  `profile_complete?/1` keys on.

  Validates only the fields actually being set: `tools` must be a non-empty
  list of slugs from `valid_tools/0`; `uses_obsidian` must be a boolean.
  Empty payloads (neither field) are rejected so a stray POST can't
  no-op-succeed.

  Returns `{:ok, %User{}}` or `{:error, atom}` where atom is one of
  `:invalid_uses_obsidian | :empty_tools | :invalid_tool | :nothing_to_set`.
  """
  def set_profile(user, attrs) when is_map(attrs) do
    has_tools = Map.has_key?(attrs, :tools)
    has_source = Map.has_key?(attrs, :uses_obsidian)

    cond do
      not has_tools and not has_source ->
        {:error, :nothing_to_set}

      has_tools and not is_list(Map.get(attrs, :tools)) ->
        {:error, :empty_tools}

      has_tools and Map.get(attrs, :tools) == [] ->
        {:error, :empty_tools}

      has_tools and Enum.any?(Map.get(attrs, :tools), &(&1 not in @valid_tools)) ->
        {:error, :invalid_tool}

      has_source and not is_boolean(Map.get(attrs, :uses_obsidian)) ->
        {:error, :invalid_uses_obsidian}

      true ->
        existing = current_profile(user) || %{}

        merged =
          existing
          |> maybe_put_field(attrs, :tools, "tools")
          |> maybe_put_field(attrs, :uses_obsidian, "uses_obsidian")
          |> maybe_stamp_completed_at()

        user
        |> Ecto.Changeset.change(onboarding_profile: merged)
        |> Repo.update(skip_tenant_check: true)
    end
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
    has_tools = match?([_ | _], Map.get(profile, "tools"))
    has_source = is_boolean(Map.get(profile, "uses_obsidian"))
    has_stamp = is_binary(Map.get(profile, "completed_at"))

    if has_tools and has_source and not has_stamp do
      Map.put(profile, "completed_at", DateTime.utc_now(:second) |> DateTime.to_iso8601())
    else
      profile
    end
  end

  # Re-read the column rather than trusting the caller's struct — callers that
  # just ran `set_profile/2` and then `status/1` would otherwise see a stale
  # `nil` and the gate would stick on `:vault` even after a successful save.
  defp current_profile(user) do
    import Ecto.Query

    from(u in Engram.Accounts.User,
      where: u.id == ^user.id,
      select: u.onboarding_profile
    )
    |> Repo.one(skip_tenant_check: true)
  end

  defp profile_complete?(%{"completed_at" => ts}) when is_binary(ts), do: true
  defp profile_complete?(_), do: false

  # Cache-first read of the user's latest accepted version for a document.
  defp accepted_version(user, document) do
    case TermsCache.accepted_version(user.id, document) do
      nil ->
        v = query_accepted_version(user, document)
        if v, do: TermsCache.put_accepted(user.id, document, v)
        v

      cached ->
        cached
    end
  end

  defp accepted_satisfies?(nil, _floor), do: false
  defp accepted_satisfies?(_accepted, nil), do: true
  defp accepted_satisfies?(accepted, floor), do: accepted >= floor

  # A notice is due when there is a current version the user hasn't accepted yet.
  defp notice(_document, nil, _accepted), do: nil

  defp notice(document, current, accepted)
       when is_nil(accepted) or current > accepted do
    case Legal.get(document, current) do
      nil ->
        nil

      row ->
        %{
          document: document,
          version: row.version,
          effective_date: row.effective_date,
          material: row.material,
          changelog: row.changelog,
          accept_url: "https://app.engram.page/onboard/agreement"
        }
    end
  end

  defp notice(_document, _current, _accepted), do: nil

  defp query_accepted_version(user, document) do
    import Ecto.Query

    from(a in Agreement,
      where: a.user_id == ^user.id and a.document == ^document,
      order_by: [desc: a.accepted_at],
      limit: 1,
      select: a.version
    )
    |> Repo.one(skip_tenant_check: true)
  end

  defp next_step(false, _, _, _, _), do: :agreement
  defp next_step(true, false, _, _, _), do: :billing

  # Profile incomplete: chain through :tools then :vault. `:tools` step is
  # complete when the user has POSTed `tools`; `:vault` step is complete when
  # they've POSTed `uses_obsidian` (and, for fresh-path users, a vault row
  # exists). Both POSTs land via `set_profile/2`; once the second arrives,
  # `maybe_stamp_completed_at/1` latches `profile_complete?: true`.
  defp next_step(true, true, false, profile, _) do
    if profile_has_tools?(profile), do: :vault, else: :tools
  end

  defp next_step(true, true, true, _profile, has_vault) do
    # Wizard navigation requires an actual vault row regardless of source —
    # Obsidian-path users wait here until the plugin's first sync creates one
    # (the `vault_populated` channel broadcast then unblocks the wizard). Note
    # the asymmetry with `RequireOnboarding`: the plug still SKIPS the vault
    # gate for `uses_obsidian=true` so the plugin can actually push that first
    # sync — runtime permission and wizard navigation are intentionally
    # separated. See `EngramWeb.Plugs.RequireOnboarding`.
    if has_vault, do: :done, else: :vault
  end

  defp profile_has_tools?(%{"tools" => [_ | _]}), do: true
  defp profile_has_tools?(_), do: false

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
  end

  @doc """
  Record an onboarding milestone for `user_id`. Idempotent — re-recording the
  same action returns `:ok` with no extra row. Returns `{:error, changeset}`
  only on enum/validation failure.
  """
  def record_action(user_id, action) when is_atom(action) do
    record_action(user_id, Atom.to_string(action))
  end

  def record_action(user_id, action) when is_integer(user_id) and is_binary(action) do
    %Action{}
    |> Action.changeset(%{user_id: user_id, action: action})
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:user_id, :action],
      skip_tenant_check: true
    )
    |> case do
      {:ok, _} -> :ok
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
    end
  end

  @doc """
  Return the set of onboarding actions recorded for `user_id` as a list of
  string action names. Empty list for unknown user.
  """
  def list_actions(user_id) when is_integer(user_id) do
    import Ecto.Query

    from(a in Action, where: a.user_id == ^user_id, select: a.action)
    |> Repo.all(skip_tenant_check: true)
  end
end
