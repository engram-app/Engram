defmodule Engram.Accounts do
  @moduledoc """
  Account management: Clerk auth, API keys, JWT.
  """

  import Ecto.Query
  alias Bcrypt
  alias Engram.Accounts.{ApiKey, Lifecycle, User}
  alias Engram.Auth.{DeviceRefreshToken, EmailNormalizer, RefreshToken, SessionInvalidator}
  alias Engram.Logger.Metadata
  alias Engram.Repo

  @api_key_prefix "engram_"

  def get_user!(id), do: get_user_uncached(id) || raise(Ecto.NoResultsError, queryable: User)

  @doc """
  A fresh `users` read (no cache), nil when the user is gone. For a gate that
  must see live state, e.g. `RotationGate.check_user/1` on a worker's user.
  """
  def get_user_uncached(id), do: Repo.get(User, id, skip_tenant_check: true)

  @doc """
  Cached (`:user`, evicted by the `users_changed` trigger on any UPDATE or
  DELETE). The struct carries the enforcement fields the auth plugs read
  (`deleted_at`, `suspended_at`, `dek_rotation_locked_at`); `subscription` is
  never loaded on it. A missing user is not cached.
  """
  def get_user(id),
    do: Engram.Cache.fetch(:user, id, fn -> Repo.get(User, id, skip_tenant_check: true) end)

  @doc """
  Load a user with `:subscription` already populated, in ONE query.

  `Billing.get_subscription/1` short-circuits when the association is loaded and
  otherwise queries — and `tier/1` calls it, so every `effective_limit/2` on a
  bare `get_user/1` struct costs a `subscriptions` round trip. A worker that
  checks a limit even twice therefore pays for two.

  `left_join` + `preload` rather than `Repo.preload/2`: the latter issues a
  SECOND query, which is the cost this exists to remove. A user with no
  subscription gets `nil`, which `get_subscription/1` also treats as loaded — so
  the free tier benefits too rather than falling through to a query.

  For request paths that never consult a limit, prefer `get_user/1`; the join is
  only worth it when something downstream will ask about entitlements.
  """
  @spec get_user_with_subscription(Ecto.UUID.t()) :: User.t() | nil
  def get_user_with_subscription(id) do
    Repo.with_tenant!(id, fn -> Repo.one(with_subscription_query(id)) end)
  end

  @doc """
  `get_user_with_subscription/1` that raises, for callers replacing a
  `get_user!/1` and relying on a missing user being an error rather than a
  `nil` that flows onward.
  """
  @spec get_user_with_subscription!(Ecto.UUID.t()) :: User.t()
  def get_user_with_subscription!(id) do
    Repo.with_tenant!(id, fn -> Repo.one!(with_subscription_query(id)) end)
  end

  # `users` has no RLS, but the joined `subscriptions` row is the user's own
  # tenant data (#1758): unscoped, the join comes back nil under an enforced
  # policy and a paying user silently resolves to `:free`. Callers therefore
  # run it inside `with_tenant/2` for the user being loaded.
  defp with_subscription_query(id) do
    from(u in User,
      where: u.id == ^id,
      left_join: s in assoc(u, :subscription),
      preload: [subscription: s]
    )
  end

  # ── Clerk Auth ─────────────────────────────────────────────────

  @doc """
  Finds a user by external ID. Returns {:ok, user} or {:error, :user_not_found}.
  Used by local auth where users must already exist (created via /register).
  """
  def find_by_external_id(external_id) do
    case Repo.one(from(u in User, where: u.external_id == ^external_id), skip_tenant_check: true) do
      %User{} = user -> {:ok, user}
      nil -> {:error, :user_not_found}
    end
  end

  @doc """
  Looks up a user by their pre-computed `normalized_email`. Returns
  `{:error, :user_not_found}` when no row exists. Used by the Clerk webhook
  handler to reject signup duplicates (pricing v2 §A).
  """
  def find_by_normalized_email(normalized_email) when is_binary(normalized_email) do
    case Repo.one(from(u in User, where: u.normalized_email == ^normalized_email),
           skip_tenant_check: true
         ) do
      %User{} = user -> {:ok, user}
      nil -> {:error, :user_not_found}
    end
  end

  @doc """
  Finds a user by external ID (Clerk sub), or links/creates one.

  Priority: external_id match > email match (link external_id) > create new user.

  The email match only claims a row with no `external_id` yet (a local/legacy
  account). A row already bound to a DIFFERENT Clerk id is never relinked:
  that would hand the account to whoever presents a token with the same
  email (#1868). Returns `{:error, :external_id_conflict}` instead.

  Consequence: a Clerk instance swap mints new ids for every user, so existing
  rows need an explicit `external_id` migration; sign-in will not relink them.
  """
  def find_or_create_by_external_id(external_id, attrs, retries \\ 1)

  def find_or_create_by_external_id(external_id, %{email: email}, retries) do
    case Repo.one(from(u in User, where: u.external_id == ^external_id), skip_tenant_check: true) do
      %User{} = user ->
        {:ok, user}

      nil ->
        case Repo.one(from(u in User, where: u.email == ^email), skip_tenant_check: true) do
          %User{external_id: nil} = user ->
            user
            |> Ecto.Changeset.change(%{external_id: external_id})
            |> Repo.update(skip_tenant_check: true)

          %User{} = user ->
            require Logger

            Logger.warning(
              "Clerk external_id conflict: email already bound to another Clerk user; refusing relink",
              Metadata.with_category(:warning, :auth,
                user_id: user.id,
                clerk_user_id: external_id
              )
            )

            {:error, :external_id_conflict}

          nil ->
            %User{}
            |> Ecto.Changeset.change(%{
              external_id: external_id,
              email: email,
              normalized_email: EmailNormalizer.normalize(email)
            })
            |> Ecto.Changeset.unique_constraint(:email, name: :users_email_lower_index)
            |> Ecto.Changeset.unique_constraint(:external_id, name: :users_clerk_id_index)
            |> Ecto.Changeset.unique_constraint(:normalized_email,
              name: :users_normalized_email_index
            )
            |> Repo.insert(skip_tenant_check: true)
            |> case do
              {:ok, user} ->
                {:ok, user}

              {:error, %Ecto.Changeset{errors: [{field, _}]}}
              when field in [:email, :external_id] and retries > 0 ->
                # Concurrent request won the insert — retry finds the winner
                find_or_create_by_external_id(external_id, %{email: email}, retries - 1)

              {:error, changeset} ->
                {:error, changeset}
            end
        end
    end
  end

  # ── Local Auth ─────────────────────────────────────────────────

  # Advisory lock key for bootstrap admin assignment — arbitrary fixed integer
  @admin_bootstrap_lock 739_201

  # Serializes admin-count-sensitive ops (bootstrap admin claim,
  # set_role/suspend/soft_delete) on one global advisory lock so concurrent
  # callers can't race the active-admin count.
  #
  # Gated off in test (`config :engram, :admin_bootstrap_lock_enabled, false`):
  # the Ecto SQL sandbox wraps each test in one long-lived transaction, so a
  # `pg_advisory_xact_lock` is held for the *entire test* rather than just the
  # claim — under async concurrency that global lock deadlocks (issue #619).
  # Role assignment itself is row-based (`Instance.bootstrap_pending?/0`) and
  # stays correct without the lock; only true-concurrent first-signups (a
  # one-time, near-impossible window) rely on it, and those don't occur across
  # isolated sandbox transactions. Defaults true → prod path is unchanged.
  defp acquire_admin_bootstrap_lock do
    _ =
      if Application.get_env(:engram, :admin_bootstrap_lock_enabled, true) do
        Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock($1)", [
          @admin_bootstrap_lock
        ])
      end

    :ok
  end

  @max_password_bytes 72

  def create_user_with_password(email, password)
      when byte_size(password) >= 8 and byte_size(password) <= @max_password_bytes do
    cleaned_email = email |> String.trim() |> String.downcase()
    normalized = EmailNormalizer.normalize(email)
    external_id = Ecto.UUID.generate()
    password_hash = Bcrypt.hash_pwd_salt(password)

    Repo.transaction(
      fn ->
        # Serialize bootstrap claim so two concurrent first-time signups can't
        # both become admin. The second one enters the tx after the first
        # commits, sees bootstrap_pending? == false, and is created as member.
        acquire_admin_bootstrap_lock()

        bootstrap_pending = Engram.Instance.bootstrap_pending?()
        role = if bootstrap_pending, do: "admin", else: "member"

        with {:ok, user} <-
               %User{
                 email: cleaned_email,
                 normalized_email: normalized,
                 external_id: external_id,
                 password_hash: password_hash,
                 role: role
               }
               |> Ecto.Changeset.change()
               |> Ecto.Changeset.unique_constraint(:email, name: :users_email_lower_index)
               |> Ecto.Changeset.unique_constraint(:normalized_email,
                 name: :users_normalized_email_index
               )
               |> Repo.insert(skip_tenant_check: true),
             :ok <- maybe_close_bootstrap(bootstrap_pending) do
          user
        else
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end,
      skip_tenant_check: true
    )
  end

  def create_user_with_password(_email, password)
      when byte_size(password) > @max_password_bytes do
    {:error, :password_too_long}
  end

  def create_user_with_password(_email, _password) do
    {:error, :password_too_short}
  end

  defp maybe_close_bootstrap(true) do
    case Engram.Instance.mark_bootstrap_complete() do
      {:ok, _} -> :ok
      {:error, cs} -> {:error, cs}
    end
  end

  defp maybe_close_bootstrap(false), do: :ok

  @max_display_name_chars 80

  # A BCP 47 language tag: a 2-3 letter language, then optional subtags
  # ("zh-Hant-TW", "es-419"). 35 is the longest tag the RFC recommends handling.
  @locale_format ~r/\A[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*\z/
  @max_locale_chars 35

  @doc """
  Record a user's objection to analytics (privacy policy 2026-10-12) and erase
  their PostHog person. Every emitter then skips them via
  `Engram.Analytics`. Users flip it from Settings (`PATCH /api/me`); an
  operator handling a privacy@ request runs it from a release shell:
  `{:ok, u} = find_by_normalized_email(EmailNormalizer.normalize(email))`, then
  `set_analytics_opt_out(u)`. A repeat keeps the original time and queues
  erasure again. Our own copy (`analytics_events` and the daily snapshots) is
  deleted with it, so withdrawing the objection later brings nothing back. The
  stamp, the deletes and the erasure jobs commit together or not at all.
  """
  @spec set_analytics_opt_out(User.t()) :: {:ok, User.t()} | {:error, term()}
  def set_analytics_opt_out(%User{} = user) do
    Repo.transact(fn ->
      with {:ok, updated} <-
             user
             |> Ecto.Changeset.change(
               analytics_opt_out_at: user.analytics_opt_out_at || DateTime.utc_now()
             )
             |> Repo.update(skip_tenant_check: true),
           :ok <- Engram.Analytics.erase(user) do
        :ok = delete_analytics_history(user.id)
        Repo.after_commit(fn -> Engram.Analytics.EventLog.discard(user.id) end)
        {:ok, updated}
      end
    end)
  end

  # Our own copy goes with the PostHog person: the event log and the daily
  # snapshots. Not tenant tables (no RLS), so no tenant scope applies.
  defp delete_analytics_history(user_id) do
    for schema <- [
          Engram.Analytics.Event,
          Engram.Insights.UserDailyMetric,
          Engram.Insights.VaultDailyMetric
        ] do
      Repo.delete_all(from(r in schema, where: r.user_id == ^user_id))
    end

    :ok
  end

  @doc """
  Withdraw a user's objection to analytics. Capture resumes on their next
  request. Pending erasures are cancelled in the same transaction, so none can
  delete what they send after consenting again.
  """
  @spec clear_analytics_opt_out(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def clear_analytics_opt_out(%User{} = user) do
    Repo.transact(fn ->
      with {:ok, updated} <-
             user
             |> Ecto.Changeset.change(analytics_opt_out_at: nil)
             |> Repo.update(skip_tenant_check: true) do
        :ok = Engram.Analytics.cancel_pending_erasure(updated)
        {:ok, updated}
      end
    end)
  end

  @doc """
  Updates the editable profile fields on a user: `display_name` and `locale`
  (the UI language, a BCP 47 tag). An empty/whitespace `display_name` clears
  it (stored as nil).
  """
  def update_profile(%User{} = user, attrs) do
    user
    |> profile_changeset(attrs)
    |> Repo.update(skip_tenant_check: true)
  end

  defp profile_changeset(user, attrs) do
    user
    |> Ecto.Changeset.cast(attrs, [:display_name, :locale], empty_values: [])
    |> Ecto.Changeset.update_change(:display_name, fn
      nil ->
        nil

      val ->
        case String.trim(val) do
          "" -> nil
          trimmed -> trimmed
        end
    end)
    |> Ecto.Changeset.validate_length(:display_name,
      max: @max_display_name_chars,
      count: :codepoints
    )
    |> Ecto.Changeset.validate_length(:locale, max: @max_locale_chars)
    |> Ecto.Changeset.validate_format(:locale, @locale_format)
    |> reject_null_locale()
    |> Ecto.Changeset.update_change(:locale, &canonical_locale/1)
  end

  # The account always has a language once set: a client that serializes an
  # unset field as null must not erase it. (validate_* skip nil changes.)
  defp reject_null_locale(changeset) do
    case Ecto.Changeset.fetch_change(changeset, :locale) do
      {:ok, nil} -> Ecto.Changeset.add_error(changeset, :locale, "can't be blank")
      _ -> changeset
    end
  end

  # BCP 47 casing ("PT-br" -> "pt-BR", "zh-hant-tw" -> "zh-Hant-TW"), so one
  # language is stored one way. Runs after validate_format: the tag is ASCII.
  defp canonical_locale(nil), do: nil

  defp canonical_locale(tag) do
    [language | subtags] = String.split(tag, "-")
    Enum.join([String.downcase(language) | Enum.map(subtags, &canonical_subtag/1)], "-")
  end

  defp canonical_subtag(<<_::binary-size(4)>> = script), do: String.capitalize(script)
  defp canonical_subtag(<<_::binary-size(2)>> = region), do: String.upcase(region)
  defp canonical_subtag(other), do: String.downcase(other)

  @doc "Sets a new bcrypt password hash for a user (local auth)."
  def update_password(%User{} = user, new_password)
      when is_binary(new_password) and byte_size(new_password) >= 8 and
             byte_size(new_password) <= @max_password_bytes do
    user
    |> Ecto.Changeset.change(password_hash: Bcrypt.hash_pwd_salt(new_password))
    |> Repo.update(skip_tenant_check: true)
  end

  def update_password(_user, pw) when is_binary(pw) and byte_size(pw) < 8,
    do: {:error, :password_too_short}

  def update_password(_user, pw) when is_binary(pw),
    do: {:error, :password_too_long}

  @doc """
  Self-delete flow for local-auth users:
    1. verify password
    2. block if this is the last active admin
    3. `Engram.Accounts.Lifecycle.delete_account/2` — stamps `deleted_at` +
       revokes tokens + emails, then `hard_delete/2` purges every store
       (Paddle, S3, Postgres cascade, Clerk; Qdrant by a job after commit).

  Previously this set `deleted_at` and waited 30 days for the inactivity
  sweep to purge. The account-lifecycle work removes that wait — user-
  initiated delete is now immediate-cascade. Audit/reason atom flows
  through to `[:engram, :account, :deleted]` telemetry as `:user`.
  """
  def delete_self(%User{deleted_at: %DateTime{}, password_hash: hash} = user, password)
      when is_binary(password) do
    # Half-state recovery. Attempt 1 stamped `deleted_at` but something
    # between then and `hard_delete` failed (network glitch, PG txn
    # rollback, process crash). `verify_password` now rejects them with
    # `{:error, :deleted}`, so without this clause they'd wait for the
    # inactivity sweep's hard-delete pass. The password is still checked
    # here: `AccountLifecycle` lets only this route through for a deleted
    # account, and a token alone must not be enough to purge it.
    # `hard_delete` is idempotent; re-run it and let the next failure surface.
    if is_binary(hash) and Bcrypt.verify_pass(password, hash),
      do: Lifecycle.hard_delete(user, :user),
      else: {:error, :invalid_password}
  end

  def delete_self(%User{} = user, password) when is_binary(password) do
    with {:ok, _} <- verify_password(user.email, password),
         :ok <- guard_last_admin(user) do
      Lifecycle.delete_account(user, :user)
    else
      {:error, :invalid_credentials} -> {:error, :invalid_password}
      {:error, :last_admin} -> {:error, :last_admin}
      {:error, other} -> {:error, other}
    end
  end

  defp guard_last_admin(%User{role: "admin"} = _user) do
    if active_admin_count() <= 1, do: {:error, :last_admin}, else: :ok
  end

  defp guard_last_admin(_user), do: :ok

  # Sentinel revocation timestamp used by admin and breach paths. Pinned at
  # epoch 0 so it always falls OUTSIDE `Engram.Auth.RefreshLeeway` — without
  # this the next request after a logout-everywhere or family breach would
  # land inside the leeway window, get misread as a benign rotation race,
  # and silently re-issue a fresh token (defeating the revocation). Keeping
  # the rows preserves audit history for `Engram.Connections.any_history?`
  # and `device_history?`, which distinguish "already revoked" from "never
  # existed" by row presence.
  @admin_revoked_at ~U[1970-01-01 00:00:00Z]

  @doc """
  Spec §8/§10 — revokes all of a user's refresh tokens (logout-everywhere,
  password reset, account delete): session tokens and plugin device tokens.
  Device rows take the sentinel too, so this never reads as a Disconnect
  and starts no device-swap cooldown (`Connections.most_recent_device_revoke/1`).
  """
  def revoke_all_user_tokens(%User{id: user_id}) do
    result =
      RefreshToken
      |> where([rt], rt.user_id == ^user_id and is_nil(rt.revoked_at))
      |> Repo.update_all([set: [revoked_at: @admin_revoked_at]], skip_tenant_check: true)

    # Not a tenant table: no RLS (see `DeviceFlow.cleanup_expired/0`).
    DeviceRefreshToken
    |> where([rt], rt.user_id == ^user_id and is_nil(rt.revoked_at))
    |> Repo.update_all(set: [revoked_at: @admin_revoked_at])

    SessionInvalidator.disconnect_user(user_id)
    result
  end

  def verify_password(email, password) do
    # Case-insensitive on `email` (backed by `users_email_lower_index`), NOT
    # `normalized_email`: that column collapses gmail dots/plus tags for dup
    # detection, so matching on it would accept aliases as login identifiers.
    login_email = email |> String.trim() |> String.downcase()

    case Repo.one(from(u in User, where: fragment("lower(?)", u.email) == ^login_email),
           skip_tenant_check: true
         ) do
      %User{password_hash: hash} = user when is_binary(hash) ->
        # Spec §10: block suspended/deleted at the login chokepoint. Check after
        # password verification so timing matches the wrong-password path.
        cond do
          not Bcrypt.verify_pass(password, hash) -> {:error, :invalid_credentials}
          not is_nil(user.suspended_at) -> {:error, :suspended}
          not is_nil(user.deleted_at) -> {:error, :deleted}
          true -> {:ok, user}
        end

      %User{password_hash: nil} ->
        Bcrypt.no_user_verify()
        {:error, :invalid_credentials}

      nil ->
        Bcrypt.no_user_verify()
        {:error, :invalid_credentials}
    end
  end

  # ── Refresh Tokens ─────────────────────────────────────────────

  @refresh_token_ttl_days 30
  # Leeway-window policy lives in `Engram.Auth.RefreshLeeway` so both
  # local-auth and device-flow refresh paths share the same window.

  def create_refresh_token(user, family_id \\ nil) do
    raw_token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    token_hash = hash_refresh_token(raw_token)
    family_id = family_id || Ecto.UUID.generate()

    case %RefreshToken{}
         |> RefreshToken.changeset(%{
           user_id: user.id,
           token_hash: token_hash,
           family_id: family_id,
           expires_at:
             DateTime.add(DateTime.utc_now(), @refresh_token_ttl_days * 24 * 3600, :second)
             |> DateTime.truncate(:second)
         })
         |> Repo.insert(skip_tenant_check: true) do
      {:ok, record} -> {:ok, raw_token, record}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def consume_refresh_token(raw_token) do
    token_hash = hash_refresh_token(raw_token)
    now = DateTime.utc_now(:second)

    tx_result =
      Repo.transaction(
        fn ->
          # Atomically revoke: only succeeds if token exists and is not yet revoked
          revoke_query =
            from(rt in RefreshToken,
              where: rt.token_hash == ^token_hash and is_nil(rt.revoked_at),
              select: rt
            )

          case Repo.update_all(revoke_query, [set: [revoked_at: now]], skip_tenant_check: true) do
            {1, [token]} ->
              if DateTime.compare(now, token.expires_at) == :gt do
                Repo.rollback(:expired)
              else
                rotate_into_child(token)
              end

            {0, _} ->
              classify_unrotated(token_hash, now)
          end
        end,
        skip_tenant_check: true
      )

    case tx_result do
      {:ok, {user, new_raw, new_record}} ->
        {:ok, user, new_raw, new_record}

      {:error, {:token_reused, reused_token_hash}} ->
        # Revoke entire family OUTSIDE the transaction so it actually commits
        revoke_token_family(reused_token_hash)
        {:error, :token_reused}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Rotate `token` into a fresh child within its family. Guards on user
  # suspended/deleted state (same chokepoint as `verify_password/2`). The
  # 2-arity overload takes a preloaded user (used by `classify_unrotated/2`
  # which already loads the user in its lookup query, avoiding an N+1); the
  # 1-arity overload fetches the user separately and is used by the
  # just-revoked-now path which can't preload through update_all.
  defp rotate_into_child(token) do
    user =
      Repo.one!(from(u in Engram.Accounts.User, where: u.id == ^token.user_id),
        skip_tenant_check: true
      )

    rotate_into_child(token, user)
  end

  defp rotate_into_child(token, %Engram.Accounts.User{} = user) do
    cond do
      not is_nil(user.suspended_at) -> Repo.rollback(:suspended)
      not is_nil(user.deleted_at) -> Repo.rollback(:deleted)
      true -> :ok
    end

    case create_refresh_token(user, token.family_id) do
      {:ok, new_raw, new_record} -> {user, new_raw, new_record}
      {:error, _reason} -> Repo.rollback(:refresh_token_creation_failed)
    end
  end

  # No row was just-revoked, so either the token never existed, was previously
  # revoked, or is being raced. Inside the leeway → benign concurrent rotation,
  # issue a child; outside → genuine reuse, breach. Preloads :user so the
  # leeway-branch rotation doesn't need a separate user fetch.
  defp classify_unrotated(token_hash, now) do
    case Repo.one(
           from(rt in RefreshToken,
             where: rt.token_hash == ^token_hash,
             preload: [:user]
           ),
           skip_tenant_check: true
         ) do
      nil ->
        Repo.rollback(:invalid_token)

      %RefreshToken{revoked_at: revoked, user: user} = revoked_token when revoked != nil ->
        if Engram.Auth.RefreshLeeway.benign?(revoked_token, now) do
          rotate_into_child(revoked_token, user)
        else
          Repo.rollback({:token_reused, token_hash})
        end

      %RefreshToken{} ->
        Repo.rollback(:invalid_token)
    end
  end

  def revoke_token_family(family_id_or_token_hash) do
    family_id =
      case Repo.one(
             from(rt in RefreshToken,
               where: rt.token_hash == ^family_id_or_token_hash,
               select: rt.family_id
             ),
             skip_tenant_check: true
           ) do
        nil -> family_id_or_token_hash
        fid -> fid
      end

    require Logger

    Logger.warning(
      "refresh-token reuse detected; revoking family family_id=#{family_id}",
      Metadata.with_category(:warning, :auth, [])
    )

    # Mark every still-live member of the family as revoked using the
    # `@admin_revoked_at` sentinel (epoch 0). Stamping with `now` would put
    # them inside the leeway window so a follow-up request with the current
    # child would be mistaken for a benign rotation race and re-issue tokens —
    # defeating the revocation. Deleting (the prior approach) broke
    # `Connections.any_history?`, which distinguishes "already revoked" from
    # "never existed" by row presence. Sentinel gives us both: leeway always
    # closes, and history queries still see the row.
    # Snapshot the distinct user_ids in the family BEFORE revoke so we can
    # force-disconnect every affected user's live sockets — the realtime
    # gate in UserSocket is connect-time only.
    affected_user_ids =
      Repo.all(
        from(rt in RefreshToken,
          where: rt.family_id == ^family_id and is_nil(rt.revoked_at),
          select: rt.user_id,
          distinct: true
        ),
        skip_tenant_check: true
      )

    result =
      from(rt in RefreshToken, where: rt.family_id == ^family_id and is_nil(rt.revoked_at))
      |> Repo.update_all([set: [revoked_at: @admin_revoked_at]], skip_tenant_check: true)

    Enum.each(affected_user_ids, &SessionInvalidator.disconnect_user/1)
    result
  end

  @doc "SHA-256 hash a raw refresh token for storage/lookup."
  def hash_refresh_token(raw_token), do: Engram.Crypto.sha256_hex(raw_token)

  # ── Encryption ─────────────────────────────────────────────────

  @doc """
  Updates encryption-related fields on a user. Used by Engram.Crypto during
  DEK provisioning. Separate from general user updates so the change surface
  is narrow.
  """
  @spec update_user_encryption(Engram.Accounts.User.t(), map()) ::
          {:ok, Engram.Accounts.User.t()} | {:error, Ecto.Changeset.t()}
  def update_user_encryption(%User{} = user, attrs) do
    user
    |> Ecto.Changeset.cast(attrs, [:encrypted_dek, :dek_version, :key_provider])
    |> Ecto.Changeset.validate_required([:encrypted_dek, :dek_version, :key_provider])
    |> Repo.update(skip_tenant_check: true)
    |> tap(&evict_user_on_ok(&1, user.id))
  end

  @doc """
  Drops the cached `get_user/1` row on this node and broadcasts to peers.

  The `users_changed` trigger already evicts every node on commit, but its
  NOTIFY lands asynchronously. Writers of the fields the request gates read
  (`deleted_at`, `suspended_at`, `dek_rotation_locked_at`, `encrypted_dek`,
  onboarding state) call this after commit so a read on the writing node right
  after the write cannot see the old row. Calling it inside a transaction is
  pointless: a concurrent read can re-cache the pre-commit row.
  """
  @spec evict_user(Ecto.UUID.t()) :: :ok
  def evict_user(user_id), do: Engram.Cache.evict(:user, user_id)

  defp evict_user_on_ok({:ok, _}, user_id), do: evict_user(user_id)
  defp evict_user_on_ok(_, _), do: :ok

  # ── JWT ─────────────────────────────────────────────────────────

  def generate_jwt(user, extras \\ %{}) do
    # `sub` + `email` match what the active auth provider's verify_token expects
    # (Local provider rejects tokens missing them with :missing_claims). `user_id`
    # is kept for the internal-JWT fallback in TokenResolver and for any callers
    # that look it up by integer DB id.
    #
    # `extras` lets OAuth-issued tokens carry `scope` + `vault_id` claims so the
    # MCP plug (Phase 5) can enforce vault scope without an extra DB lookup.
    base = %{
      "sub" => user.external_id,
      "email" => user.email,
      "user_id" => user.id
    }

    Engram.Token.generate_and_sign!(Map.merge(base, stringify_keys(extras)))
  end

  defp stringify_keys(%{} = map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  @doc """
  The claims of an Engram-issued (HS256) token whose SIGNATURE verifies,
  without re-checking `exp`, `iss` or `aud`. `:error` for anything else,
  including a Clerk token, an API key or a forged signature.

  Only for a token this request (or socket connect) has ALREADY
  authenticated in full through `Engram.Auth.TokenResolver`. Re-validating it
  is what `OAuthScopeEnforce` and `UserSocket` used to do, and a token in its
  last second could pass the resolver and then fail the re-check, so its
  grant claims read as absent, which means unrestricted. Skipping only the
  time and audience checks of an already-validated token removes that race
  without trusting anything unsigned.
  """
  #
  # An OAuth access token's `gid` (its grant) is resolved here too
  # (`Engram.OAuth.expand_claims/1`), so both readers get the grant's levels
  # and both see a revoke at once. `:revoked` is OUR token whose grant is gone:
  # every caller refuses it, whatever path authenticated it.
  @spec grant_claims(term()) :: {:ok, %{String.t() => term()}} | :error | :revoked
  def grant_claims(token) when is_binary(token) do
    case Engram.Token.verify(token) do
      {:ok, claims} -> Engram.OAuth.expand_claims(claims)
      {:error, _} -> :error
    end
  end

  def grant_claims(_token), do: :error

  def verify_jwt(token) do
    case Engram.Token.verify_and_validate(token) do
      {:ok, claims} -> {:ok, claims}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── API Keys ────────────────────────────────────────────────────

  @doc """
  Creates an API key. `access` is nil for a key on every vault (the pre-#332
  behaviour), or `{levels, default}` as `Engram.Permissions.parse_access_params/1`
  returns it: a level ("none" | "read" | "write") per vault plus the level for
  every vault not listed, including ones created later. Every listed vault
  must be one of the user's active vaults, or the key is not created
  (`{:error, :invalid_access}`).

  A leveled key is minted in a raw form whose stored hash a release that
  predates levels never computes, so that release refuses it (see the note
  on `hash_api_key/1`).
  """
  def create_api_key(user, name, access \\ nil) do
    raw_key = mint_raw_key(access)
    key_hash = hash_api_key(raw_key)

    result =
      Repo.with_tenant(user.id, fn ->
        with {:ok, rows, default} <- key_access(user, access),
             {:ok, api_key} <-
               %ApiKey{}
               |> ApiKey.changeset(%{
                 key_hash: key_hash,
                 name: name,
                 user_id: user.id,
                 default_access: default
               })
               |> Repo.insert() do
          insert_key_vaults(api_key, rows)
          {:ok, api_key}
        end
      end)

    case result do
      {:ok, {:ok, api_key}} -> {:ok, raw_key, api_key}
      {:ok, {:error, reason}} -> {:error, reason}
    end
  end

  defp key_access(_user, nil), do: {:ok, [], nil}

  defp key_access(user, access) do
    case Engram.Permissions.resolve_access(user, access) do
      {:ok, levels, default} -> {:ok, Map.to_list(levels), default}
      :error -> {:error, :invalid_access}
    end
  end

  defp insert_key_vaults(_api_key, []), do: :ok

  defp insert_key_vaults(api_key, rows) do
    {_, _} =
      Repo.insert_all(
        "api_key_vaults",
        for {vault_id, level} <- rows do
          %{
            api_key_id: Ecto.UUID.dump!(api_key.id),
            vault_id: Ecto.UUID.dump!(vault_id),
            level: level
          }
        end
      )

    :ok
  end

  def validate_api_key(raw_key) do
    key_hash = hash_api_key(raw_key)

    # Tenant DISCOVERY, not a tenant bypass: the user_id is what this lookup
    # returns, so there is nothing to scope by until it has already succeeded.
    #
    # `api_keys_discovery` (the no-tenant read policy) is scoped TO
    # `engram_key_lookup` by the #1867 contract migration, after which plain
    # engram_app sees no keys without a tenant. The key read (with its vault
    # scope) runs as that role: SELECT on api_keys and api_key_vaults.
    # Cost: one transaction and two extra round trips per API-key MISS; the
    # key is cached by hash (`:api_key`), evicted by the `api_keys_changed`
    # trigger on revoke (row delete) and by `revoke_api_key/2` locally.
    # The user is resolved separately through the cached `get_user/1`, so a
    # user's state change never has to evict the key.
    with {%ApiKey{} = key, _scope} <- cached_api_key(key_hash),
         %User{} = user <- get_user(key.user_id) do
      :ok = touch_api_key(key)
      {:ok, user, key}
    else
      nil -> {:error, :invalid_key}
    end
  end

  @key_used_debounce_seconds 3600

  # Stamps `api_keys.last_used` (the connections page's "last used") at most
  # once an hour per key per node: the `:api_key_used` cache holds the last
  # stamp, and a node that has none trusts the one on the key row. The UPDATE
  # repeats the hour test, so nodes racing on the same key write once. The
  # stamp does not evict the `:api_key` cache (the trigger skips last_used),
  # which is why that cache's copy of it is only a floor.
  defp touch_api_key(%ApiKey{id: id, user_id: user_id, last_used: stored}) do
    last =
      case Engram.Cache.get(:api_key_used, id) do
        {:ok, ts} -> ts
        :miss -> stored
      end

    if key_used_stale?(last) do
      now = DateTime.utc_now(:second)
      cutoff = DateTime.add(now, -@key_used_debounce_seconds, :second)

      Repo.with_tenant!(user_id, fn ->
        Repo.update_all(
          from(k in ApiKey,
            where: k.id == ^id and (is_nil(k.last_used) or k.last_used < ^cutoff)
          ),
          set: [last_used: now]
        )
      end)

      Engram.Cache.put(:api_key_used, id, now)
    else
      Engram.Cache.put(:api_key_used, id, last)
    end
  end

  defp key_used_stale?(nil), do: true

  defp key_used_stale?(%DateTime{} = ts),
    do: DateTime.diff(DateTime.utc_now(), ts, :second) >= @key_used_debounce_seconds

  @doc """
  `{%ApiKey{}, vault_scope}` for a key hash, or nil for no such key. Cached as
  ONE `:api_key` entry so the scope (`:all | [vault_id]`, see
  `Vaults.accessible_vault_ids/1`) can never outlive or reload apart from the
  key row: a revoked one-vault key whose mapping rows are gone must not come
  back as unrestricted.
  """
  @spec cached_api_key(String.t()) ::
          {ApiKey.t(), :all | [Ecto.UUID.t()] | Engram.Permissions.scope()} | nil
  def cached_api_key(key_hash),
    do: Engram.Cache.fetch(:api_key, key_hash, fn -> lookup_key(key_hash) end)

  defp lookup_key(key_hash) do
    {:ok, key} =
      Repo.transaction(fn ->
        _ =
          Repo.query!("SELECT set_config('role', 'engram_key_lookup', true)", [],
            source: "api_key_lookup_enter"
          )

        # Key and scope in ONE statement (one snapshot): read apart, a
        # CleanupVault committing between them (key and mapping rows deleted
        # together) returned the key with `:all` scope. No mapping rows means
        # unrestricted.
        row =
          Repo.cross_tenant(fn ->
            Repo.one(
              from(k in ApiKey,
                where: k.key_hash == ^key_hash,
                select:
                  {k,
                   fragment(
                     "(SELECT jsonb_object_agg(v.vault_id, v.level) FROM public.api_key_vaults AS v WHERE v.api_key_id = ?)",
                     k.id
                   )}
              )
            )
          end)

        # SET LOCAL survives a savepoint release, so reset inside (see
        # `Repo.run_with_tenant/2`).
        _ =
          Repo.query!("SELECT set_config('role', 'none', true)", [],
            source: "api_key_lookup_exit"
          )

        case row do
          nil -> nil
          {key, rows} -> {key, key_scope(key, Map.to_list(rows || %{}))}
        end
      end)

    key
  end

  # A pre-#332 key keeps its historical cached shape (`:all | [vault_id]`,
  # which `Vaults.accessible_vault_ids/1` documents); a leveled key is cached
  # as its `Engram.Permissions` scope.
  defp key_scope(%ApiKey{default_access: nil}, []), do: :all
  defp key_scope(%ApiKey{default_access: nil}, rows), do: Enum.map(rows, &elem(&1, 0))

  defp key_scope(%ApiKey{default_access: default}, rows),
    do: Engram.Permissions.from_key(default, rows)

  def list_api_keys(user) do
    {:ok, keys} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(from(k in ApiKey, where: k.user_id == ^user.id, order_by: [desc: k.created_at]))
      end)

    keys
  end

  def revoke_api_key(user, api_key_id) do
    result =
      Repo.with_tenant(user.id, fn ->
        case Repo.get_by(ApiKey, id: api_key_id, user_id: user.id) do
          nil -> {:error, :not_found}
          key -> Repo.delete(key)
        end
      end)

    case result do
      {:ok, {:ok, key}} ->
        # The trigger evicts every node on commit; this closes the window on
        # the writing node without waiting for the NOTIFY round trip.
        Engram.Cache.evict(:api_key, key.key_hash)
        SessionInvalidator.disconnect_user(user.id)
        :ok

      {:ok, {:error, :not_found}} ->
        {:error, :not_found}

      {:ok, {:error, changeset}} ->
        {:error, changeset}
    end
  end

  @doc """
  Replaces a leveled key's vault access (`{levels, default}`, as parsed by
  `Engram.Permissions.parse_access_params/1`) in place: the raw key, and so
  its hash, are unchanged. Effective at once: the `:api_key` entry is evicted
  here and on every node by the `api_keys_changed` / `api_key_vaults_changed`
  triggers, and the user's live sockets reconnect, as on a revoke.

  `{:error, :legacy_key}` for a pre-levels key (`default_access` NULL): it is
  stored under the plain hash a pre-levels release reads, which would take
  read levels as write after a rollback (see the encoding note below). The
  user creates a new key instead. `{:error, :invalid_access}` for a vault
  that is not one of the user's active vaults; `{:error, :not_found}` for a
  key that is not the user's.
  """
  @spec update_api_key_access(User.t(), Ecto.UUID.t(), {map(), String.t()}) ::
          {:ok, ApiKey.t()} | {:error, :not_found | :legacy_key | :invalid_access}
  def update_api_key_access(user, api_key_id, access) do
    result =
      Repo.with_tenant(user.id, fn ->
        key =
          Repo.one(
            from(k in ApiKey,
              where: k.id == ^api_key_id and k.user_id == ^user.id,
              lock: "FOR UPDATE"
            )
          )

        cond do
          is_nil(key) -> {:error, :not_found}
          is_nil(key.default_access) -> {:error, :legacy_key}
          true -> replace_key_access(user, key, access)
        end
      end)

    case result do
      {:ok, {:ok, key}} ->
        Engram.Cache.evict(:api_key, key.key_hash)
        SessionInvalidator.disconnect_user(user.id)
        {:ok, key}

      {:ok, error} ->
        error
    end
  end

  defp replace_key_access(user, key, access) do
    with {:ok, rows, default} <- key_access(user, access) do
      Repo.delete_all(
        from(v in "api_key_vaults", where: v.api_key_id == type(^key.id, Ecto.UUID))
      )

      insert_key_vaults(key, rows)
      key |> Ecto.Changeset.change(default_access: default) |> Repo.update()
    end
  end

  # FAIL-CLOSED COMPATIBILITY ENCODING for leveled keys (#332). A release that
  # predates levels looks a key up by `sha256_hex(raw)` and reads its
  # `api_key_vaults` rows as write on each (no rows = every vault), ignoring
  # `level` and `default_access`. A leveled key found there would turn read
  # into write and a policy-only key into an all-vaults key. A sentinel row
  # (as OAuth grants use) is impossible: `api_key_vaults.vault_id` is a
  # foreign key to `vaults`.
  #
  # So a leveled key is stored under a DIFFERENT hash, one an old release
  # never computes: it gets 401 and cannot be widened at all. The raw form
  # says which hash applies: `engram_lk_` plus 43 random characters (53 in
  # all). A pre-levels key is `engram_` plus 43 (50 in all), so even one whose
  # random part happens to start `lk_` is shorter and keeps the plain hash:
  # the two forms cannot collide. Pre-levels keys are unchanged.
  @leveled_key_prefix "engram_lk_"
  @key_random_chars 43

  defp mint_raw_key(access) do
    prefix = if access, do: @leveled_key_prefix, else: @api_key_prefix
    prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end

  defp hash_api_key(@leveled_key_prefix <> random = raw_key)
       when byte_size(random) == @key_random_chars,
       do: Engram.Crypto.sha256_hex("leveled:" <> raw_key)

  defp hash_api_key(raw_key), do: Engram.Crypto.sha256_hex(raw_key)

  # ── Admin user management (self-host) ──────────────────────────

  @doc "Lists active (non-deleted) users, newest first."
  def list_users do
    Repo.all(
      from(u in User, where: is_nil(u.deleted_at), order_by: [desc: u.created_at]),
      skip_tenant_check: true
    )
  end

  @doc "Count of active (non-suspended, non-deleted) admins."
  def active_admin_count do
    Repo.aggregate(
      from(u in User,
        where: u.role == "admin" and is_nil(u.deleted_at) and is_nil(u.suspended_at)
      ),
      :count,
      skip_tenant_check: true
    )
  end

  @doc "Sets a user's role. Refuses to demote the last active admin."
  def set_role(%User{} = user, role) when role in ~w(admin member) do
    with_admin_lock(fn ->
      user = Repo.reload!(user, skip_tenant_check: true)

      if demoting_last_admin?(user, role) do
        Repo.rollback(:last_admin)
      else
        case user
             |> Ecto.Changeset.change(role: role)
             |> Repo.update(skip_tenant_check: true) do
          {:ok, u} -> u
          {:error, cs} -> Repo.rollback(cs)
        end
      end
    end)
  end

  def set_role(%User{}, _role), do: {:error, :invalid_role}

  defp demoting_last_admin?(%User{role: "admin"} = user, "member"),
    do: is_nil(user.suspended_at) and is_nil(user.deleted_at) and active_admin_count() <= 1

  defp demoting_last_admin?(_, _), do: false

  @doc "Suspends a user (blocks login + refresh). Refuses the last active admin."
  def suspend(%User{} = user) do
    result =
      with_admin_lock(fn ->
        user = Repo.reload!(user, skip_tenant_check: true)

        if would_orphan_admins?(user) do
          Repo.rollback(:last_admin)
        else
          case user
               |> Ecto.Changeset.change(suspended_at: DateTime.utc_now())
               |> Repo.update(skip_tenant_check: true) do
            {:ok, u} -> u
            {:error, cs} -> Repo.rollback(cs)
          end
        end
      end)

    disconnect_on_commit(result)
  end

  @doc "Clears suspension."
  def unsuspend(%User{} = user) do
    user
    |> Ecto.Changeset.change(suspended_at: nil)
    |> Repo.update(skip_tenant_check: true)
    |> tap(&evict_user_on_ok(&1, user.id))
  end

  @doc "Soft-deletes a user. Refuses the last active admin."
  def soft_delete_user(%User{} = user) do
    result =
      with_admin_lock(fn ->
        user = Repo.reload!(user, skip_tenant_check: true)

        if would_orphan_admins?(user) do
          Repo.rollback(:last_admin)
        else
          case user
               |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
               |> Repo.update(skip_tenant_check: true) do
            {:ok, u} -> u
            {:error, cs} -> Repo.rollback(cs)
          end
        end
      end)

    disconnect_on_commit(result)
  end

  # Fire SessionInvalidator only after the admin-lock transaction COMMITS so
  # a rolled-back suspend/soft-delete does not spuriously kick live sockets.
  defp disconnect_on_commit({:ok, %User{id: user_id}} = ok) do
    evict_user(user_id)
    SessionInvalidator.disconnect_user(user_id)
    ok
  end

  defp disconnect_on_commit(other), do: other

  # Serializes admin-count-sensitive ops (set_role/suspend/soft_delete) against
  # each other via the same advisory lock that gates bootstrap. Without it,
  # two concurrent demotes of different admins could each pass the
  # active_admin_count <= 1 check and leave zero admins.
  defp with_admin_lock(fun) do
    Repo.transaction(
      fn ->
        acquire_admin_bootstrap_lock()

        fun.()
      end,
      skip_tenant_check: true
    )
  end

  defp would_orphan_admins?(%User{role: "admin", suspended_at: nil, deleted_at: nil}),
    do: active_admin_count() <= 1

  defp would_orphan_admins?(_), do: false

  @doc """
  Spec §7 — enqueues a forced `CleanupVault` for every vault a user owns
  (active + soft-deleted). Skips the `Vaults.list_vaults/1` DEK-decrypt chain,
  since the purge only needs vault ids.

  Scoped with `Repo.with_tenant!/2` because `vaults` carries FORCE ROW LEVEL
  SECURITY. Unscoped, the enumeration is filtered to `[]` under any role the
  policy applies to, `Enum.each/2` iterates nothing, and the admin DELETE
  endpoint answers `{"ok": true}` while the user's vaults, attachments and
  storage blobs are never reaped. Nothing raises and nothing logs.

  This previously read with `skip_tenant_check: true`, and the docstring
  claimed that "bypasses RLS". It does not: that option only silences the
  application-level `prepare_query/3` tripwire and sets no Postgres session
  state. See docs/context/database-schema-rls.md ("skip_tenant_check,
  cross_tenant/1, maintenance()"). Prod enforces RLS since 2026-09-25
  (engram-infra#1243).

  The enqueue runs INSIDE the tenant transaction, and a failed insert raises.
  Both matter, because `Oban.insert/1` returns `{:error, changeset}` rather
  than raising: an `Enum.each/2` that discards it reproduces the exact silent
  failure this function was fixed for, one line lower. Raising is what rolls
  the batch back; returning an error tuple instead would commit the partial
  batch and leave vault 1 reaped, vault 3 not, and nothing retrying.

  Two consequences of raising, neither obvious:

    * The caller gets a generic 500, NOT a rendered error.
      `EngramWeb.FallbackController` only runs on an `{:error, _}` return
      value, so a raise bypasses it and surfaces via `Sentry.PlugCapture`.
    * "Rolls the batch back" is true only of THIS transaction.
      `soft_delete_user/1` has already committed in its own transaction by the
      time this runs, so on a raise the user stays soft-deleted with zero
      cleanup jobs. The admin operation as a whole is not atomic.

  That second one is survivable because the purge is re-drivable:
  `soft_delete_user/1` re-stamps `deleted_at` with no already-deleted guard and
  `Repo.get!` still finds a soft-deleted row, so re-issuing the admin DELETE
  runs the purge again.

  PRECONDITION: raises if called from inside a `Repo.with_tenant/2` block for
  a DIFFERENT tenant. The only caller is the admin DELETE path, which holds no
  tenant when it gets here.

  Returns the number of vaults enqueued.
  """
  def purge_user_vaults(%User{id: user_id}) do
    require Logger

    Repo.with_tenant!(user_id, fn ->
      vaults = Repo.all(from(v in Engram.Vaults.Vault, where: v.user_id == ^user_id))

      Enum.each(vaults, fn v ->
        case Engram.Workers.CleanupVault.enqueue_now(v.id, user_id) do
          {:ok, _job} ->
            :ok

          # Only the changeset's ERRORS, never the changeset itself.
          # `inspect/1` on a struct in a message body is the shape this repo
          # bans: `Engram.Logger.RedactFilter` deliberately does not touch
          # message bodies, and this string reaches both the crash log and
          # Sentry. `errors` is bounded and is the part that says why.
          #
          # `Metadata.safe_reason/1` is not used for the changeset branch on
          # purpose: its `%mod{}` clause renders just "Ecto.Changeset" and
          # throws the constraint name away.
          {:error, %Ecto.Changeset{errors: errors}} ->
            raise "purge_user_vaults: CleanupVault enqueue failed for vault " <>
                    "#{v.id} (user #{user_id}): #{inspect(errors)}"

          {:error, other} ->
            raise "purge_user_vaults: CleanupVault enqueue failed for vault " <>
                    "#{v.id} (user #{user_id}): " <>
                    Metadata.safe_reason(other)
        end
      end)

      length(vaults)
    end)
    |> tap(fn count ->
      # Logged AFTER the transaction returns, not inside it. Inside, the line
      # asserts "enqueued N" while those rows are still uncommitted, so a
      # connection drop or statement timeout before COMMIT leaves a log claiming
      # jobs that do not exist — the same report-success-while-doing-nothing
      # shape this function exists to remove, one layer up.
      #
      # An irreversible admin action that previously did nothing at all, so it
      # says how much it did.
      Logger.info(
        "purge_user_vaults enqueued #{count} CleanupVault job(s)",
        Metadata.with_category(:info, :lifecycle, user_id: user_id)
      )
    end)
  end
end
