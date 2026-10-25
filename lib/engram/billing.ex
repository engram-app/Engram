defmodule Engram.Billing do
  @moduledoc """
  Billing context: Paddle event processing, tier/trial queries, customer
  portal redirect, and plan-based limits enforcement. Checkout itself
  happens client-side in the Paddle.js overlay — the backend only reacts
  to webhooks.
  """

  import Ecto.Query

  alias Engram.Billing.EntitlementCache
  alias Engram.Billing.LimitKeys
  alias Engram.Billing.PlanCache
  alias Engram.Billing.Subscription
  alias Engram.Billing.UserLimitOverride
  alias Engram.Logger.Metadata
  alias Engram.Paddle.Client
  alias Engram.Repo

  require Logger

  defmodule UnknownLimitKeyError do
    @moduledoc "Raised when a limit lookup uses an unknown atom or a string key."
    defexception [:key]

    def message(%{key: k}),
      do: "unknown limit key: #{inspect(k)} (atoms only, must be in LimitKeys.all/0)"
  end

  # ── Limits ────────────────────────────────────────────────────────

  # The four dialects of "no ceiling" that `effective_limit/2` can return.
  # Named once so `cap/2`, `check_limit/3` and `limit_enforced?/2` cannot drift.
  @no_cap [:unlimited, nil, -1]

  @doc """
  Returns the effective limit for a given key for a user.

  Resolution order, first hit wins:
    1. user_limit_overrides[key]           (per-user, live via OverrideCache)
    2. ENGRAM_<TIER>_<KEY> env             (:plan_overrides, parsed at boot)
    3. plans[user.plan_id].limits[key]
    4. LimitKeys.default_for(key, tier)

  Step 3 is effectively dead: `users.plan_id` is written only in tests, so
  every production user resolves through 1, 2 or 4. Step 2 is the one an
  operator actually reaches, and it is a PULL model keyed off
  `LimitKeys.env_var_names/0` — an env var whose key is not in the catalog is
  never read and never warns.

  Uses explicit nil-checking (not ||) so that `false` values are honoured.
  Raises `Engram.Billing.UnknownLimitKeyError` for string keys or atoms not in
  `LimitKeys.all/0`.
  """
  def effective_limit(user, key) when is_atom(key) do
    unless LimitKeys.defined?(key), do: raise(UnknownLimitKeyError, key: key)

    if enforced?() do
      do_effective_limit(user, key)
    else
      :unlimited
    end
  end

  def effective_limit(_user, key), do: raise(UnknownLimitKeyError, key: key)

  @doc """
  What `effective_limit/2` gives every `tier` user with no per-user
  override: the plan env override, else the catalog default, and
  `:unlimited` with enforcement off. For sweeps that apply a limit to many
  users in one query; pair it with `active_overrides/1`. Skips the
  `plan_id` step, which only tests write.
  """
  def tier_limit(tier, key) when is_atom(key) do
    unless LimitKeys.defined?(key), do: raise(UnknownLimitKeyError, key: key)

    if enforced?() do
      case env_override_lookup(tier, key) do
        {:hit, v} -> v
        :miss -> LimitKeys.default_for(key, tier)
      end
    else
      :unlimited
    end
  end

  @doc """
  The per-user overrides of `key` that `effective_limit/2` reads right now:
  `[{user_id, value}]`, unexpired, null values left out (a null override is
  a miss there too).
  """
  def active_overrides(key) when is_atom(key) do
    now = DateTime.utc_now()

    from(o in UserLimitOverride,
      where: o.key == ^to_string(key) and (is_nil(o.expires_at) or o.expires_at > ^now),
      select: {o.user_id, fragment("?->'v'", o.value)}
    )
    # `user_limit_overrides` has no RLS: no tenant to set, no guard to skip.
    |> Repo.all()
    |> Enum.reject(&is_nil(elem(&1, 1)))
  end

  defp enforced?, do: Application.get_env(:engram, :limits_enforced, true)

  defp do_effective_limit(user, key) do
    user_tier = tier(user)
    string_key = to_string(key)

    with :miss <- user_override_lookup(user.id, string_key),
         :miss <- legacy_override_lookup(user.id, key),
         :miss <- env_override_lookup(user_tier, key),
         :miss <- plan_lookup(user, string_key) do
      LimitKeys.default_for(key, user_tier)
    else
      {:hit, v} -> v
    end
  end

  @doc """
  THE answer to "may this user upload non-text attachments?".

  Every caller — the plugin's `plan_state/1` pre-gate payload, the web app's
  `capabilities/1` map, and the upload controller — must route through this one
  function. They used to each re-derive it, and `capabilities/1` got it
  backwards whenever enforcement was off, which is how self-hosters silently
  lost every image and PDF while the server would have accepted them.

  `:unlimited` (enforcement off, i.e. self-host) means yes, same as every other
  grant-shaped capability.
  """
  @spec attachments_all_types?(Engram.Accounts.User.t()) :: boolean()
  def attachments_all_types?(%Engram.Accounts.User{} = user) do
    # Mirrors `normalize_capability(:boolean, _)`: only `:unlimited` and a real
    # `true` grant. Anything else fails CLOSED. `!= false` would have been
    # fail-open — a hand-written override row holding the string "false"
    # instead of the boolean would then hand a Free user the paid attachment
    # surface, which the `== true` code this replaced correctly refused.
    case effective_limit(user, :attachments_all_types) do
      :unlimited -> true
      true -> true
      _ -> false
    end
  end

  @doc """
  Whether this user is exempt from the free-tier inactivity dunning.

  The single answer, same as `attachments_all_types?/1` — but the fail
  direction is deliberately the OPPOSITE, and that is a decision, not an
  oversight. Failing "closed" on a grant normally means refusing it, which for
  attachments means refusing an upload: harmless. Refusing THIS grant means
  mailing the user about inactivity and starting the deletion clock. On a value
  we cannot read, the safe answer is to leave them alone, so anything that is
  not an explicit `false` counts as exempt.

  `:unlimited` (enforcement off, i.e. self-host) is exempt: a self-hosted
  instance must never send free-tier dunning about its operator's own data.
  """
  @spec inactivity_warnings_exempt?(Engram.Accounts.User.t()) :: boolean()
  def inactivity_warnings_exempt?(%Engram.Accounts.User{} = user) do
    effective_limit(user, :inactivity_warnings_exempt) != false
  end

  @doc """
  The resolved integer ceiling for `key` as a NUMBER, or `nil` when there is not
  a usable one.

  `effective_limit/2` speaks four dialects of "no cap" — `:unlimited`
  (enforcement off, i.e. self-host), `nil` (the catalog's unmetered default),
  `-1` (the documented operator-override sentinel) and a real integer. Every
  caller that wants a number had to decode all four, and before this function
  existed eight modules did it independently under seven different private
  names (`normalize_cap`, `normalize_int`, `as_int`, `cap_json`, ...).

  They did not agree. `Engram.Accounts.Export`'s copy passed `-1` through
  intact, so an operator override meaning "unlimited exports" resolved to a
  ceiling of -1 and `count >= -1` refused EVERY export — the same
  enforcement-off-inverts-the-rule shape that `LimitKeys`' polarity note
  describes for `attachments_text_only`. Decode in one place and that class
  cannot come back per-caller.

  ## This is the DISPLAY/DIAL decoder, not the gate

  A malformed override also answers `nil` here. `UserLimitOverride`'s changeset
  validates the KEY against the catalog and never the value's type, so
  `%{"v" => "2000"}` is storable, and this function honours its `@spec` rather
  than handing a string to arithmetic. That makes `cap(user, key) || default`
  safe, which is the whole point — a dial or a progress bar must not raise on a
  corrupt row.

  It also means `cap/2` fails OPEN and therefore **cannot be the gate**. The
  gate pair is `limit_enforced?/2` + `check_limit/3`, which read
  `effective_limit/2` directly and both treat an unreadable value as a real
  ceiling (fail CLOSED). For a corrupt row the two deliberately disagree:
  `limit_enforced?/2` says yes, `cap/2` says nil, and a caller that uses both —
  `Engram.Notes.check_notes_cap/2` is the pattern — refuses the write and
  reports a null limit in the 402. Refusing is the safe half; showing a
  fabricated number is not.

  Do not "fix" that disagreement by defining one in terms of the other.
  """
  @spec cap(term(), atom()) :: integer() | nil
  def cap(user, key) do
    case effective_limit(user, key) do
      -1 -> nil
      n when is_integer(n) -> n
      _ -> nil
    end
  end

  @doc """
  Days a deleted item stays restorable for `user` (#609), at least 1.

  `trash_retention_days` read through `cap/2`. Every "no cap" spelling,
  self-host's enforcement-off included, takes the Pro default instead: for
  retention, unlimited cannot mean "keep forever" without the blob GC never
  reaping anything.
  """
  @spec trash_retention_days(term()) :: pos_integer()
  def trash_retention_days(user) do
    case cap(user, :trash_retention_days) || LimitKeys.default_for(:trash_retention_days, :pro) do
      days when is_integer(days) and days >= 1 -> days
      _ -> 1
    end
  end

  @doc """
  `cap/2` for a whole tier, ignoring per-user overrides: the env override,
  else the catalog default. nil means no ceiling. For reports over many users
  that read the overrides in one query instead of one lookup per user.
  """
  @spec tier_cap(:free | :starter | :pro, atom()) :: integer() | nil
  def tier_cap(tier, key) do
    limit =
      case {enforced?(), env_override_lookup(tier, key)} do
        {false, _} -> nil
        {true, {:hit, v}} -> v
        {true, :miss} -> LimitKeys.default_for(key, tier)
      end

    if is_integer(limit) and limit >= 0, do: limit
  end

  @spec granted?(term(), atom()) :: boolean()
  def granted?(user, key), do: check_feature(user, key) == :ok

  @doc """
  Returns :ok if current_count is below the limit, or the limit is -1 (unlimited).
  Returns {:error, :limit_reached} when at or over the limit.
  """
  def check_limit(user, key, current_count) do
    case effective_limit(user, key) do
      limit when limit in @no_cap -> :ok
      limit when is_integer(limit) and current_count < limit -> :ok
      _ -> {:error, :limit_reached}
    end
  end

  @doc """
  Whether `key` imposes a real ceiling on this user.

  `check_limit/3` answers `:ok` for `:unlimited`, `nil` and `-1` **without ever
  reading `current_count`** — so a caller that computes an expensive count and
  then passes it in has done that work for nothing whenever the cap does not
  apply. On the embed path that was one `usage_meters` aggregate per job for
  every Starter/Pro user, since the resolver returns `nil` for unmetered plans.

  Call this first and skip measuring when it returns `false`:

      if Billing.limit_enforced?(user, :some_cap) do
        case Billing.check_limit(user, :some_cap, expensive_count()) do
  ...

  Shares `effective_limit/2` with `check_limit/3` so the two cannot disagree
  about what "unlimited" means — the predicate exists to reorder the work, not
  to re-encode the rule. `BillingLimitPredicateTest` pins that agreement.
  """
  @spec limit_enforced?(term(), atom()) :: boolean()
  def limit_enforced?(user, key) when is_atom(key) do
    effective_limit(user, key) not in @no_cap
  end

  @doc """
  Returns :ok if the boolean feature is enabled for the user.
  Returns {:error, :feature_not_available} otherwise.
  """
  def check_feature(user, key) do
    case effective_limit(user, key) do
      :unlimited -> :ok
      true -> :ok
      _ -> {:error, :feature_not_available}
    end
  end

  # ── Private Limit Helpers ─────────────────────────────────────────

  defp user_override_lookup(user_id, string_key) do
    # Read-through cache (60s TTL, hits AND misses): this lookup runs on
    # every effective_limit resolution and hot paths resolve several
    # limits per request, while override rows are rare admin grants.
    Engram.Billing.OverrideCache.fetch(user_id, string_key, fn ->
      now = DateTime.utc_now()

      Repo.one(
        from(o in UserLimitOverride,
          where:
            o.user_id == ^user_id and
              o.key == ^string_key and
              (is_nil(o.expires_at) or o.expires_at > ^now),
          select: fragment("?->'v'", o.value)
        ),
        skip_tenant_check: true
      )
      |> wrap_lookup()
    end)
  end

  # An override row written under a key's old name (`LimitKeys.legacy_key/1`).
  defp legacy_override_lookup(user_id, key) do
    case LimitKeys.legacy_key(key) do
      nil -> :miss
      old -> user_override_lookup(user_id, old)
    end
  end

  defp env_override_lookup(tier, key) do
    case Application.get_env(:engram, :plan_overrides, %{}) |> Map.fetch({tier, key}) do
      {:ok, v} -> {:hit, v}
      :error -> :miss
    end
  end

  defp plan_lookup(%{plan_id: nil}, _string_key), do: :miss

  defp plan_lookup(%{plan_id: id}, string_key) do
    id
    |> PlanCache.limits()
    |> Map.get(string_key)
    |> wrap_lookup()
  end

  defp wrap_lookup(nil), do: :miss
  defp wrap_lookup(v), do: {:hit, v}

  # ── Tier & Status Queries ──────────────────────────────────────

  # Subscription statuses that entitle a user to their paid tier:
  #   * `active`   — paying, current.
  #   * `trialing` — paid plan with a deferred first charge (card-on-file);
  #     the whole point is full paid access during the window.
  #   * `past_due` — payment failed but Paddle is retrying within the
  #     dunning grace window; a transient card decline shouldn't strip
  #     features mid-cycle. (Data retention already treats past_due as
  #     paid — see `Engram.Workers.InactivityCleanup`.)
  # `paused`/`canceled` do NOT entitle: the subscription has lapsed, so the
  # user drops to Free until it recovers.
  @entitled_statuses ~w(active trialing past_due)

  @doc """
  The subscription statuses that entitle a user to their paid tier.

  Public so SQL-side callers that cannot run the full `tier/1` resolver
  (`Engram.Workers.ReconcileEmbeddings`) can filter on the same list instead of
  hand-rolling a subset. A hand-rolled subset that dropped `past_due` silently
  stalled the dense backfill for entitled users in dunning.
  """
  @spec entitled_statuses() :: [String.t()]
  def entitled_statuses, do: @entitled_statuses

  @doc "True on an entitled paid plan. The one paid-plan rule; callers ask this."
  @spec paid?(Engram.Accounts.User.t()) :: boolean()
  def paid?(%Engram.Accounts.User{} = user), do: tier(user) in [:starter, :pro]

  @doc """
  Returns the user's effective tier as an atom in `[:free, :starter, :pro]`.

  An `active`, `trialing`, or `past_due` paid subscription resolves to
  `:starter` or `:pro` (see `@entitled_statuses` for the rationale — trials
  and dunning grace both keep access). Everyone else — un-onboarded users,
  self-host, paused / canceled subscriptions — resolves to `:free`. Always
  returns an atom (never `nil`); the un-onboarded path is gated upstream by
  `RequireOnboarding` but a Free default keeps `effective_limit/2` and
  `default_for/2` total.
  """
  @spec tier(Engram.Accounts.User.t()) :: :free | :starter | :pro
  def tier(%Engram.Accounts.User{} = user) do
    case get_subscription(user) do
      %Subscription{status: s, tier: "starter"} when s in @entitled_statuses -> :starter
      %Subscription{status: s, tier: "pro"} when s in @entitled_statuses -> :pro
      _ -> :free
    end
  end

  @doc """
  Plan/limit snapshot the Obsidian plugin needs to pre-gate attachments and
  recover after an upgrade. Sent on `user:{id}` channel join and on the
  `subscription_activated` broadcast. Numeric `:unlimited` limits serialize to
  `nil` (JSON null) so the wire shape stays `number | null`.
  """
  def plan_state(%Engram.Accounts.User{} = user) do
    all_types? = attachments_all_types?(user)

    %{
      tier: tier(user),
      attachments_all_types: all_types?,
      blocked_extensions: advertised_blocked_extensions(),
      max_file_bytes: numeric_limit(user, :max_file_bytes),
      attachment_bytes_cap: numeric_limit(user, :attachment_bytes_cap),
      # COMPAT SHIM, remove in a later contract PR. The search-coverage cap was
      # removed (every stored note is searchable on every tier), but plugins
      # from before the removal still parse this field. nil means uncapped
      # there, which is now always true.
      indexed_notes_cap: nil
    }
  end

  @doc """
  Extensions clients should refuse before uploading. Empty under
  ATTACHMENT_MIME_BYPASS, where the server accepts executables.
  """
  @spec advertised_blocked_extensions() :: [String.t()]
  def advertised_blocked_extensions do
    if Engram.Storage.MimeWhitelist.bypass?(),
      do: [],
      else: Engram.Storage.MimeWhitelist.blocked_extensions()
  end

  defp numeric_limit(user, key) do
    case effective_limit(user, key) do
      :unlimited -> nil
      # -1 is this codebase's "unlimited" sentinel — check_limit/3 documents it
      # and normalize_capability/2 already maps it to nil. Passing it through as
      # a literal -1 means every client has to know the convention, and one that
      # does not inverts the limit: a cap of -1 reads as "nothing is allowed" on
      # the most permissive plan. Same inverted-sentinel class as the
      # restriction-shaped booleans that once blocked self-host attachments
      # (removed in the pricing-v2 contract step). Normalise it here, once.
      n when is_integer(n) and n < 0 -> nil
      n when is_integer(n) -> n
      _ -> nil
    end
  end

  @doc """
  Returns the user's full, JSON-ready entitlement snapshot:

      %{tier: "free", limits: %{"notes_cap" => 3_000, "api_rps_cap" => 30, ...}}

  Every `LimitKeys` key is resolved through `effective_limit/2` and normalized:
  integer caps stay integers (`:unlimited`/`nil`/`-1` → `null`), boolean
  features stay booleans (`:unlimited` → `true`, the "limits disabled" sense).

  Backed by `Engram.Billing.EntitlementCache` (24h TTL + explicit invalidation
  on subscription/override changes) so the bootstrap path serves the whole
  matrix from one ETS read. This is advisory UX state — server-side
  `check_limit/3` / `check_feature/2` remain the authoritative gates.
  """
  @spec capabilities(Engram.Accounts.User.t()) :: %{tier: String.t(), limits: map()}
  def capabilities(%Engram.Accounts.User{id: nil} = user), do: compute_capabilities(user)

  def capabilities(%Engram.Accounts.User{} = user) do
    EntitlementCache.fetch(user.id, fn -> compute_capabilities(user) end)
  end

  defp compute_capabilities(user) do
    limits =
      Map.new(LimitKeys.all(), fn key ->
        value = normalize_capability(LimitKeys.type(key), effective_limit(user, key))
        {Atom.to_string(key), value}
      end)

    %{tier: Atom.to_string(tier(user)), limits: limits, plan_limits: plan_limits()}
  end

  # What each paid tier allows, so a client can say what an upgrade buys
  # before it refuses a file. Tier-wide (env override, else catalog default);
  # nil = no ceiling, or enforcement off.
  @upgrade_limit_keys [:max_file_bytes, :attachment_bytes_cap]
  defp plan_limits do
    Map.new([:starter, :pro], fn tier ->
      {Atom.to_string(tier),
       Map.new(@upgrade_limit_keys, &{Atom.to_string(&1), tier_cap(tier, &1)})}
    end)
  end

  # Boolean feature: :unlimited (enforcement off) opens the gate; explicit
  # true/false flows through; anything else fails closed.
  defp normalize_capability(:boolean, :unlimited), do: true
  defp normalize_capability(:boolean, true), do: true
  defp normalize_capability(:boolean, false), do: false
  defp normalize_capability(:boolean, _), do: false
  # Integer cap: "no cap" sentinels collapse to null for the wire.
  defp normalize_capability(:integer, :unlimited), do: nil
  defp normalize_capability(:integer, nil), do: nil
  defp normalize_capability(:integer, -1), do: nil
  defp normalize_capability(:integer, n) when is_integer(n), do: n
  defp normalize_capability(:integer, _), do: nil
  # String setting (e.g. per-tier query model id): the value flows through;
  # nil / :unlimited (enforcement off) / anything else → null on the wire.
  defp normalize_capability(:string, value) when is_binary(value), do: value
  defp normalize_capability(:string, _), do: nil

  @doc """
  Returns true when the user is not suspended. Tier defaults to `:free`
  for un-onboarded users — see `tier/1`. Account access is gated by
  suspension only; tier-based feature gating happens via
  `effective_limit/2` and `check_limit/3` / `check_feature/2`.
  """
  @spec active?(Engram.Accounts.User.t()) :: boolean()
  def active?(%Engram.Accounts.User{} = user) do
    is_nil(user.suspended_at)
  end

  @doc """
  Loads the user's subscription (or nil). Reuses an already-preloaded
  `:subscription` association when present so the auth pipeline can load it
  once per request and have `tier/1`, `active?/1`, and `effective_limit/2`
  share that single read instead of each issuing its own query.
  """
  def get_subscription(%{subscription: %Subscription{} = sub}), do: sub
  def get_subscription(%{subscription: nil}), do: nil
  # Non-persisted user (built but not inserted) — no row to load. Keeps
  # `tier/1` total over `build(:user, ...)` for unit tests that don't need
  # a DB round-trip.
  def get_subscription(%{id: nil}), do: nil

  # Scoped to the user's own tenant (#1758): under an enforced `subscriptions`
  # policy an unscoped read returns nil, and `tier/1` would quietly answer
  # `:free` for a paying user. Cached per user (`:subscription`, nil included),
  # evicted on every node by the `subscriptions_changed` trigger.
  def get_subscription(user) do
    Engram.Cache.fetch(:subscription, user.id, fn ->
      Repo.with_tenant!(user.id, fn ->
        Repo.one(from(s in Subscription, where: s.user_id == ^user.id))
      end)
    end)
  end

  @doc """
  `user` with its subscription loaded, so every `tier/1` read one request makes
  (a create resolves several limits) hits memory instead of a tenant
  transaction each. Per-request only: the struct goes stale on a plan change,
  so never keep it on a socket or in a cache.

  Shared by the auth pipeline and the write paths. Two independent readers
  resolve a tier: the onboarding gate (`:billing_enabled`) and every limit
  check (`:limits_enforced`). They default to the same condition but
  `ENGRAM_LIMITS_ENFORCED` overrides the second alone, so either flag needs
  the row. A no-op when both are off (self-host): nothing resolves a tier
  there, so loading one would ADD a read.
  """
  @spec with_subscription(Engram.Accounts.User.t()) :: Engram.Accounts.User.t()
  def with_subscription(%Engram.Accounts.User{} = user) do
    if Application.get_env(:engram, :billing_enabled, false) or enforced?(),
      do: %{user | subscription: get_subscription(user)},
      else: user
  end

  @doc "Returns remaining trial days from the Paddle subscription, or 0."
  def trial_days_remaining(user) do
    case get_subscription(user) do
      %Subscription{status: "trialing", current_period_end: period_end}
      when period_end != nil ->
        days = DateTime.diff(period_end, DateTime.utc_now(), :day)
        max(days, 0)

      _ ->
        0
    end
  end

  @doc """
  The user's Paddle customer id (`ctm_...`), or nil before their first
  checkout. Not a secret: checkout prefills with it so a returning buyer stays
  one Paddle customer.
  """
  def paddle_customer_id(user) do
    case get_subscription(user) do
      %Subscription{paddle_customer_id: customer_id} when is_binary(customer_id) ->
        customer_id

      _ ->
        nil
    end
  end

  # ── Customer Portal ────────────────────────────────────────────

  @doc """
  Create a Paddle customer-portal session for the user's subscription and
  return the URL. Returns `{:error, :no_subscription}` if the user has no
  subscription yet.
  """
  def create_portal_session(user) do
    case get_subscription(user) do
      %Subscription{paddle_customer_id: customer_id} when is_binary(customer_id) ->
        Client.impl().create_customer_portal_session(customer_id)

      _ ->
        {:error, :no_subscription}
    end
  end

  # ── Live Paddle Read-Through (billing settings surface) ────────
  #
  # The subscription detail, payment method, and invoice history are fetched
  # live from Paddle per page load rather than persisted — the webhook row
  # only carries tier/status/period-end, and mirroring the rest would couple
  # us to stale data. All of these short-circuit to {:error, :no_subscription}
  # for users without a Paddle subscription.

  @doc """
  Fetch and normalize the user's live subscription detail: next bill, amount
  (Paddle minor units + currency for the frontend to format), billing cycle,
  and any pending `scheduled_change` (cancel/pause/plan change).
  """
  def subscription_detail(user) do
    with_paddle_subscription(user, fn sub ->
      case Client.impl().get_subscription(sub.paddle_subscription_id) do
        {:ok, raw} -> {:ok, normalize_subscription(raw)}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Fetch the user's transaction history plus the card behind the most recent
  card payment. Returns `%{payment_method: pm | nil, transactions: [...]}`.
  """
  def billing_history(user) do
    with_paddle_customer(user, fn customer_id ->
      case Client.impl().list_transactions(customer_id) do
        {:ok, txns} ->
          {:ok,
           %{
             payment_method: payment_method_from(txns),
             transactions: Enum.map(txns, &normalize_transaction/1)
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @doc """
  Mint the hosted invoice URL for one of the user's transactions. Verifies the
  transaction belongs to the user's Paddle customer before minting (IDOR guard):
  Paddle transaction IDs are otherwise enumerable across customers. Returns
  `{:error, :no_invoice}` when Paddle has no invoice for it ($0 transactions).
  """
  def transaction_invoice_url(user, transaction_id) do
    with_paddle_customer(user, fn customer_id ->
      case Client.impl().list_transactions(customer_id) do
        {:ok, txns} ->
          case Enum.find(txns, &(&1["id"] == transaction_id)) do
            nil ->
              {:error, :not_found}

            txn ->
              if invoice_available?(txn),
                do: transaction_invoice(transaction_id),
                else: {:error, :no_invoice}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  # Paddle's documented transaction id pattern.
  @paddle_transaction_id ~r/\Atxn_[a-z\d]{26}\z/

  @doc """
  The Paddle status of a checkout transaction the caller opened (its
  `custom_data.user_id`, set by `/billing/config`, names the caller). Lets
  "Try again" after an unfinished payment see a payment that landed while
  our webhook was still in Paddle's retry backoff, instead of opening a
  second checkout. `{:error, :not_found}` for anyone else's id, or an id
  Paddle does not know.
  """
  @spec checkout_transaction_status(Engram.Accounts.User.t(), String.t()) ::
          {:ok, String.t()}
          | {:error, :invalid_id | :not_found | {:rate_limited, non_neg_integer()} | term()}
  def checkout_transaction_status(user, transaction_id) do
    # The id goes into the Paddle API path under our server key, and Phoenix
    # decodes `%2F`/`%3F`: only Paddle's own id pattern reaches it.
    with :ok <- validate_transaction_id(transaction_id),
         :ok <- spend_checkout_status_budget(user.id) do
      fetch_checkout_status(user.id, transaction_id)
    end
  end

  defp validate_transaction_id(id) do
    if Regex.match?(@paddle_transaction_id, id), do: :ok, else: {:error, :invalid_id}
  end

  defp spend_checkout_status_budget(user_id) do
    opts = Application.fetch_env!(:engram, :checkout_transaction_rate_limit)

    case EngramWeb.RateLimiter.hit(
           "checkout_status:#{user_id}",
           Keyword.fetch!(opts, :period_ms),
           Keyword.fetch!(opts, :limit),
           :checkout_status
         ) do
      {:allow, _} -> :ok
      {:deny, retry_after_ms} -> {:error, {:rate_limited, retry_after_ms}}
    end
  end

  defp fetch_checkout_status(user_id, transaction_id) do
    case Client.impl().get_transaction(transaction_id) do
      {:ok, %{"status" => status, "custom_data" => %{"user_id" => ^user_id}}} -> {:ok, status}
      {:ok, _other} -> {:error, :not_found}
      {:error, {:paddle_error, 404, _}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # Paddle: "Invoice PDFs aren't available for zero-value transactions", and
  # the PDF "is available for transactions that are completed" (`billed` for
  # manual collection, where the invoice is issued before payment). Shared by
  # the invoice fetch and the history rows, so the Download button and the
  # endpoint agree. `past_due` is deliberately absent: Paddle's
  # get-transaction-invoice docs list only `billed` and `completed` (checked
  # 2026-10-24), and an automatic past_due transaction is an unpaid renewal.
  defp invoice_available?(txn) do
    txn["status"] in ~w(completed billed) and
      not zero_amount?(get_in(txn, ["details", "totals", "grand_total"]))
  end

  # Paddle amounts are strings in the lowest currency unit. Unparseable or
  # missing counts as zero: never offer an invoice we cannot vouch for.
  defp zero_amount?(amount) when is_binary(amount) do
    case Integer.parse(amount) do
      {n, ""} -> n == 0
      _ -> true
    end
  end

  defp zero_amount?(_), do: true

  # Belt to the check above: Paddle answers 404 not_found when it has no
  # invoice anyway. For a transaction we just confirmed is the caller's, that
  # means "no invoice", not a provider failure.
  defp transaction_invoice(transaction_id) do
    case Client.impl().get_transaction_invoice(transaction_id) do
      {:error, {:paddle_error, 404, _body}} -> {:error, :no_invoice}
      other -> other
    end
  end

  @doc """
  Resolve a customer-portal deep link: `"update_payment"`, or anything else
  (→ the general overview URL). There is deliberately no cancel deep link:
  cancels go through the in-app dialog, which asks why. The overview still
  offers Paddle's own cancel (Paddle requires one); a cancel made there is
  marked `portal_no_reason` when its webhook lands.
  """
  def portal_action_url(user, action) do
    case get_subscription(user) do
      %Subscription{paddle_customer_id: customer_id} = sub when is_binary(customer_id) ->
        case Client.impl().get_portal_session(customer_id) do
          {:ok, urls} -> {:ok, pick_portal_url(urls, action, sub.paddle_subscription_id)}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :no_subscription}
    end
  end

  @doc """
  Mint a transaction for an in-app payment-method update. Returns the Paddle
  transaction id for `Paddle.Checkout.open({ transactionId })`.
  """
  def update_payment_transaction(user) do
    with_paddle_subscription(user, fn sub ->
      case Client.impl().get_update_payment_transaction(sub.paddle_subscription_id) do
        {:ok, %{"id" => transaction_id}} -> {:ok, transaction_id}
        {:ok, _} -> {:error, :invalid_response}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp with_paddle_subscription(user, fun) do
    case get_subscription(user) do
      %Subscription{paddle_subscription_id: sub_id} = sub when is_binary(sub_id) ->
        fun.(sub)

      _ ->
        {:error, :no_subscription}
    end
  end

  # History and invoices follow the Paddle customer, so they survive a
  # cancel-and-resubscribe (the subscription id changes, the customer does not).
  defp with_paddle_customer(user, fun) do
    case get_subscription(user) do
      %Subscription{paddle_customer_id: customer_id} when is_binary(customer_id) ->
        fun.(customer_id)

      _ ->
        {:error, :no_subscription}
    end
  end

  defp normalize_subscription(raw) do
    %{
      next_billed_at: raw["next_billed_at"],
      amount: get_in(raw, ["recurring_transaction_details", "totals", "total"]),
      currency: raw["currency_code"],
      billing_cycle: normalize_cycle(raw["billing_cycle"]),
      scheduled_change: normalize_scheduled_change(raw["scheduled_change"])
    }
  end

  defp normalize_cycle(%{"interval" => interval, "frequency" => frequency}),
    do: %{interval: interval, frequency: frequency}

  defp normalize_cycle(_), do: nil

  defp normalize_scheduled_change(%{"action" => action, "effective_at" => effective_at}),
    do: %{action: action, effective_at: effective_at}

  defp normalize_scheduled_change(_), do: nil

  defp normalize_transaction(t) do
    %{
      id: t["id"],
      billed_at: t["billed_at"] || t["created_at"],
      amount: get_in(t, ["details", "totals", "grand_total"]),
      currency: get_in(t, ["details", "totals", "currency_code"]),
      status: t["status"],
      invoice_id: t["invoice_id"],
      invoice_available: invoice_available?(t)
    }
  end

  defp payment_method_from(txns) do
    Enum.find_value(txns, fn t ->
      case t["payments"] do
        [%{"method_details" => %{"card" => card} = md} | _] when is_map(card) ->
          %{
            type: md["type"],
            card_brand: card["type"],
            last4: card["last4"],
            exp_month: card["expiry_month"],
            exp_year: card["expiry_year"]
          }

        _ ->
          nil
      end
    end)
  end

  defp pick_portal_url(urls, action, sub_id) do
    sub_urls = Enum.find(urls["subscriptions"] || [], &(&1["id"] == sub_id)) || %{}

    case action do
      "update_payment" -> sub_urls["update_subscription_payment_method"] || overview_url(urls)
      _ -> overview_url(urls)
    end
  end

  defp overview_url(urls), do: get_in(urls, ["general", "overview"])

  # ── Webhook Event Processing ───────────────────────────────────

  @subscription_events ~w(subscription.created subscription.activated subscription.updated
                          subscription.past_due subscription.canceled)

  @doc """
  Upsert a Subscription row from a verified Paddle notification.

  Handles `subscription.created`, `subscription.activated`,
  `subscription.updated`, `subscription.past_due` and `subscription.canceled`.
  All other event types are accepted but ignored.

  Paddle delivers at-least-once and out of order, so every subscription event:

    * is skipped as `{:ok, :stale}` when its `occurred_at` is older than the
      row's `last_event_occurred_at` (a delayed `subscription.updated` must
      not re-grant a canceled user), and stamps that column when applied;
    * creates the row from `custom_data.user_id` (the `subscription.created`
      path) when no row holds its `paddle_subscription_id` yet, so an update
      or cancel delivered before the create is not dropped.
  """
  def upsert_from_paddle_event(%{"event_type" => type, "data" => data} = event)
      when type in @subscription_events do
    occurred_at = event_occurred_at(event)

    existing =
      if type != "subscription.created" and is_binary(data["id"]),
        do: get_subscription_by_paddle_id(data["id"])

    case {type, existing} do
      {_, nil} -> upsert_subscription(type, data, occurred_at)
      {"subscription.canceled", sub} -> cancel_subscription(sub, data, occurred_at)
      {_, sub} -> update_subscription(sub, data, occurred_at)
    end
  end

  # #1737 — a checkout that stalls mid-payment is the only way we lose a signup
  # silently. Paddle sends us all nine `transaction.*` events and we subscribe
  # to every one, but nothing here matched them, so they fell to the catch-all
  # below and returned `{:ok, :ignored}` under a `paddle_webhook_ok` line. The
  # first time it cost us a customer (apple_pay, `action_required`, never
  # captured, 2026-09-06) we found out eleven days later by reading the Paddle
  # API by hand.
  #
  # This clause does not recover the payment — recovery is #422. It makes the
  # event greppable in Loki and countable in Prometheus, which is what we did
  # not have.
  #
  # `action_required` is NOT a failure on its own: a 3DS challenge sits there
  # for the seconds a buyer takes to approve it. So it is reported as its own
  # `reason`, and the alert (engram-infra #1157) fires only on a transaction id
  # that never reaches a `paddle_transaction_completed` line.
  def upsert_from_paddle_event(%{"event_type" => type, "data" => data})
      when type in ~w(transaction.payment_failed transaction.updated) do
    report_checkout_transaction(type, data)
  end

  # The other half of the stalled-3DS alert (engram-infra #1157): it fires on a
  # `checkout_payment_action_required` transaction id that never appears on this
  # line. Info ships to Loki for :billing (Category.loki_ship?/2).
  def upsert_from_paddle_event(%{"event_type" => "transaction.completed", "data" => data}) do
    Logger.info(
      "paddle_transaction_completed",
      Metadata.with_category(:info, :billing,
        transaction_id: data["id"],
        customer_id: data["customer_id"]
      )
    )

    {:ok, :ignored}
  end

  # Refunds and chargebacks. An adjustment carries no custom_data, so the owner
  # is found through its subscription and handed to the analytics forwarder.
  #
  # An approved chargeback of any size ends the plan. An approved FULL refund
  # ends it only when it refunds the subscription's first charge (the 14-day
  # money-back guarantee): `type: "full"` is per transaction, and support can
  # fully refund one renewal, upgrade or duplicate charge while the plan
  # should stay. Those are logged and change nothing. A refund starts as pending_approval
  # and may end rejected: neither ends anything, nor does a
  # chargeback_warning. A row already canceled is left alone, so a repeat or
  # late event never calls Paddle twice or errors.
  # Paddle does not cancel a subscription when its transaction is refunded,
  # so we cancel it now, then run the canceled entity Paddle returns through
  # the subscription.canceled clause: the one path that drops a user to
  # Free. The later subscription.canceled webhook repeats it harmlessly.
  # Everything else writes nothing.
  def upsert_from_paddle_event(%{"event_type" => type, "data" => data})
      when type in ~w(adjustment.created adjustment.updated) do
    with id when is_binary(id) <- data["subscription_id"],
         %Subscription{} = sub <- get_subscription_by_paddle_id(id) do
      cond do
        sub.status == "canceled" or not ends_plan?(data) -> {:ok, sub}
        data["action"] == "chargeback" -> cancel_for_adjustment(sub, data["id"])
        true -> refund_full_charge(sub, data)
      end
    else
      _ -> {:ok, :ignored}
    end
  end

  def upsert_from_paddle_event(%{"event_type" => type}) do
    # Debug, not warn: this is the gap-finding line, and Loki ships warn+ only.
    Logger.debug(
      "paddle_webhook_unhandled_event",
      Metadata.with_category(:debug, :billing, event_type: type)
    )

    {:ok, :ignored}
  end

  def upsert_from_paddle_event(_event), do: {:ok, :ignored}

  defp ends_plan?(%{"status" => "approved", "action" => "refund", "type" => "full"}), do: true
  defp ends_plan?(%{"status" => "approved", "action" => "chargeback"}), do: true
  defp ends_plan?(_data), do: false

  defp refund_full_charge(sub, data) do
    case first_charge?(sub, data["transaction_id"]) do
      {:ok, true} ->
        cancel_for_adjustment(sub, data["id"])

      {:ok, false} ->
        Logger.info(
          "paddle_full_refund_kept_plan",
          Metadata.with_category(:info, :billing,
            adjustment_id: data["id"],
            transaction_id: data["transaction_id"],
            paddle_subscription_id: sub.paddle_subscription_id
          )
        )

        {:ok, sub}

      {:error, reason} ->
        {:error, {:adjustment_lookup_failed, reason}}
    end
  end

  # The subscription's first charge is its earliest billed, paid or completed
  # transaction with a non-zero total (the checkout, origin web); renewals and
  # upgrades bill later. A $0 trial or 100%-off transaction is not a charge,
  # nor is an unpaid one. Paddle's billed_at is RFC 3339 UTC, so the strings
  # sort by time.
  defp first_charge?(%Subscription{paddle_customer_id: customer_id}, _txn_id)
       when not is_binary(customer_id),
       do: {:error, :no_customer_id}

  defp first_charge?(sub, transaction_id) do
    with {:ok, transactions} <- Client.impl().list_transactions(sub.paddle_customer_id) do
      first =
        transactions
        |> Enum.filter(
          &(&1["subscription_id"] == sub.paddle_subscription_id and is_binary(&1["billed_at"]) and
              &1["status"] in ~w(billed paid completed) and
              not zero_amount?(get_in(&1, ["details", "totals", "grand_total"])))
        )
        |> Enum.min_by(& &1["billed_at"], fn -> nil end)

      {:ok, is_binary(transaction_id) and match?(%{"id" => ^transaction_id}, first)}
    end
  end

  # The user-facing cancel with `:immediately`: same Paddle call, same
  # deterministic idempotency key, so created + updated cancel once.
  defp cancel_for_adjustment(sub, adjustment_id) do
    user = %Engram.Accounts.User{id: sub.user_id, subscription: sub}

    case Engram.Billing.Subscriptions.cancel(user, :immediately) do
      {:ok, canceled} ->
        Logger.info(
          "paddle_adjustment_canceled_subscription",
          Metadata.with_category(:info, :billing,
            adjustment_id: adjustment_id,
            paddle_subscription_id: sub.paddle_subscription_id
          )
        )

        apply_paddle_cancel(canceled)

      {:error, {:paddle_error, status, body} = reason} when status in 400..499 ->
        if retryable_cancel_error?(status, body),
          do: {:error, {:adjustment_cancel_failed, reason}},
          else: settle_rejected_cancel(sub, status)

      {:error, reason} ->
        {:error, {:adjustment_cancel_failed, reason}}
    end
  end

  # Paddle's "wait, then try again" answers: 429, 409 (the renewal,
  # processing and consent-review locks), any `subscription_locked_*` code
  # (400 pending changes included), and 401/403, which is our key or config
  # and heals when we fix it. Retried (500) so Paddle redelivers.
  defp retryable_cancel_error?(status, _body) when status in [401, 403, 409, 429], do: true

  defp retryable_cancel_error?(_status, %{"error" => %{"code" => "subscription_locked_" <> _}}),
    do: true

  # Clears once Paddle decides the pending refund, so waiting works.
  defp retryable_cancel_error?(_status, %{
         "error" => %{"code" => "subscription_outstanding_pending_refund"}
       }),
       do: true

  defp retryable_cancel_error?(_status, _body), do: false

  # Any other 4xx never succeeds on retry. Usually Paddle has already
  # canceled it (`subscription_is_canceled_action_invalid`: a concurrent
  # duplicate adjustment, a lost canceled webhook), so apply Paddle's state.
  # Live at Paddle is permanent; a failed read is transient.
  defp settle_rejected_cancel(sub, status) do
    case Client.impl().get_subscription(sub.paddle_subscription_id) do
      {:ok, %{"status" => "canceled"} = canceled} -> apply_paddle_cancel(canceled)
      {:ok, _live} -> {:error, {:adjustment_cancel_rejected, status}}
      {:error, reason} -> {:error, {:adjustment_cancel_failed, reason}}
    end
  end

  # Stamped with the entity's own update time, so a subscription.updated
  # from before the refund, delivered late, is skipped as stale.
  defp apply_paddle_cancel(canceled) do
    upsert_from_paddle_event(%{
      "event_type" => "subscription.canceled",
      "occurred_at" => canceled["updated_at"] || canceled["canceled_at"],
      "data" => canceled
    })
  end

  @doc """
  Emits `checkout_payment_stalled` / `checkout_payment_action_required` (log +
  `[:engram, :paddle, :checkout, :stalled]`) for a Paddle transaction whose
  newest payment attempt is stuck. The one emitter for both the webhook path
  and the reconcile scan, so engram-infra #1157's alert reads one line shape.
  `source` lands on the line as `event_type`.
  """
  @spec report_checkout_transaction(String.t(), map()) ::
          {:ok, :checkout_stalled | :ignored}
  def report_checkout_transaction(source, data) do
    # A renewal decline is dunning, not a stalled checkout: it already arrives
    # as subscription.past_due, which this module handles. Reporting it here
    # would page for an expired card on an existing subscriber, under a log
    # name that says "checkout".
    if dunning?(data) do
      {:ok, :ignored}
    else
      report_checkout_payment(source, data)
    end
  end

  @doc """
  The newest payment attempt on a Paddle transaction, or nil. Paddle orders
  payments newest-first, but that is not relied on: this sorts by `created_at`
  and falls back to the head when the field is absent.
  """
  @spec newest_payment([map()]) :: map() | nil
  def newest_payment([]), do: nil
  def newest_payment([payment]), do: payment
  def newest_payment(payments), do: Enum.max_by(payments, &(&1["created_at"] || ""))

  @stalled_payment_statuses ~w(error action_required)

  defp report_checkout_payment(type, data) do
    # `payments` is CUMULATIVE — Paddle's own transaction.completed example
    # carries [captured, error] after a buyer retries a declined card, newest
    # first. So we judge the transaction by its NEWEST attempt only. Reporting
    # every stalled entry made the counter scale with retry count instead of
    # with stalled checkouts, and re-emitted the whole history on each later
    # transaction.updated.
    case newest_payment(List.wrap(data["payments"])) do
      nil ->
        {:ok, :ignored}

      payment ->
        if stalled_payment?(payment) do
          report_stalled_checkout(type, data, payment)
          {:ok, :checkout_stalled}
        else
          {:ok, :ignored}
        end
    end
  end

  defp stalled_payment?(%{"status" => status}) when status in @stalled_payment_statuses, do: true
  defp stalled_payment?(_), do: false

  # `origin`, not `subscription_id`. Both `subscription_payment_method_change`
  # and `subscription_charge` carry a subscription id while a buyer is sitting
  # in a live checkout, and neither arrives as subscription.past_due — keying
  # on the id would silently drop exactly the failures we are here to see.
  defp dunning?(data), do: data["origin"] == "subscription_recurring"

  defp report_stalled_checkout(event_type, data, payment) do
    method = get_in(payment, ["method_details", "type"]) || "unknown"

    # The fallback arm is not dead code: without it, adding a status to
    # @stalled_payment_statuses raises CaseClauseError inside the webhook. The
    # controller rescues that and still answers 200 (webhook_controller.ex:135),
    # so Paddle does NOT retry — the event is dropped silently, which is the
    # exact blindness this clause exists to end.
    reason =
      case payment["status"] do
        "error" -> :payment_failed
        "action_required" -> :action_required
        _ -> :unknown
      end

    # `action_required` is a 3DS challenge in flight, so it gets its own message
    # rather than claiming a stall: every healthy EU card payment produces one,
    # and it is only evidence of a problem when no completion follows.
    message =
      if reason == :action_required,
        do: "checkout_payment_action_required",
        else: "checkout_payment_stalled"

    # `:warning`, not `:warn` — Category.loki_ship?/2 matches on :warning, so
    # :warn silently stamps loki_ship=false on the one line this exists to make
    # greppable.
    Logger.warning(
      message,
      Metadata.with_category(:warning, :billing,
        event_type: event_type,
        transaction_id: data["id"],
        customer_id: data["customer_id"],
        payment_status: payment["status"],
        payment_method: method,
        error_code: payment["error_code"],
        reason: reason
      )
    )

    :telemetry.execute(
      [:engram, :paddle, :checkout, :stalled],
      %{count: 1},
      %{reason: reason, method: method}
    )
  end

  # The insert path: `subscription.created`, and any other subscription event
  # for a paddle id no row holds yet (Paddle can deliver it first). Upserts on
  # `user_id`; the conflict update runs only when `upsert_conflict_guard/1`
  # passes, and a guarded no-op comes back as a stale changeset error.
  defp upsert_subscription(type, data, occurred_at) do
    case extract_user_id(data) do
      {:ok, user_id} ->
        attrs =
          data
          |> event_attrs(occurred_at, user_id)
          |> Map.merge(%{
            user_id: user_id,
            paddle_customer_id: data["customer_id"],
            paddle_subscription_id: data["id"],
            custom_data: data["custom_data"] || %{}
          })

        # :custom_data is not in the conflict update. Paddle delivers
        # at-least-once, so a retried subscription.created must NOT clobber the
        # affiliate / utm attribution captured on first delivery.
        #
        # Scoped to the user the checkout named, so the insert passes the
        # tenant policy's WITH CHECK (#1758). `mode: :savepoint` because a
        # paddle_subscription_id already held by another row trips a unique
        # index: without it that error aborts the tenant transaction and the
        # role reset dies with 25P02 instead of returning the changeset error.
        result =
          Repo.with_tenant!(user_id, fn ->
            %Subscription{}
            |> Subscription.changeset(attrs)
            |> Repo.insert(
              on_conflict: upsert_conflict_query(type),
              conflict_target: :user_id,
              mode: :savepoint,
              stale_error_field: :last_event_occurred_at
            )
          end)

        case result do
          {:ok, sub} ->
            broadcast_subscription_activated(user_id, sub)
            # A new plan can lift the index cap: the backfill starts now.
            _ = Engram.Workers.ReconcileEmbeddings.kick()
            # A connector signup's vault waits for a passing plan, and a paid
            # plan passes here rather than in the wizard. Only the insert path
            # gets here, so renewals and cancellations of a known row never
            # recreate a deleted vault (and a canceled first event fails the
            # plan check inside). Last, and it never raises.
            with %Engram.Accounts.User{} = user <- Engram.Accounts.get_user(user_id) do
              :ok = Engram.Onboarding.maybe_provision_connector_vault(user)
            end

            {:ok, sub}

          {:error, %Ecto.Changeset{errors: errors} = changeset} ->
            cond do
              error_opt(errors, :user_id, :constraint) == :foreign ->
                skip_owner_missing(data)

              error_opt(errors, :last_event_occurred_at, :stale) ->
                stale_or_wait(type, data, user_id)

              true ->
                {:error, changeset}
            end
        end

      :error ->
        {:error, :missing_user_id}
    end
  end

  # The `user_id` conflict update. Same paddle id: apply unless the event is
  # older than the stored stamp. Different paddle id (a resubscribe): replace
  # the row only when it holds no live subscription, or (created only) when
  # the event is newer than the row. So a late cancel, or a retried created,
  # for the user's OLD subscription cannot overwrite the new one.
  defp upsert_conflict_query(type) do
    not_older =
      dynamic(
        [s],
        is_nil(s.last_event_occurred_at) or
          fragment("EXCLUDED.last_event_occurred_at IS NULL") or
          s.last_event_occurred_at <= fragment("EXCLUDED.last_event_occurred_at")
      )

    same_sub =
      dynamic(
        [s],
        fragment(
          "? IS NOT DISTINCT FROM EXCLUDED.paddle_subscription_id",
          s.paddle_subscription_id
        ) and ^not_older
      )

    not_live = dynamic([s], is_nil(s.paddle_subscription_id) or s.status == "canceled")

    other_sub =
      if type == "subscription.created",
        do: dynamic([s], ^not_live or ^not_older),
        else: not_live

    other_sub =
      dynamic(
        [s],
        fragment("? IS DISTINCT FROM EXCLUDED.paddle_subscription_id", s.paddle_subscription_id) and
          ^other_sub
      )

    from(s in Subscription,
      where: ^dynamic([s], ^same_sub or ^other_sub),
      update: [
        set: [
          paddle_customer_id: fragment("EXCLUDED.paddle_customer_id"),
          paddle_subscription_id: fragment("EXCLUDED.paddle_subscription_id"),
          tier: fragment("EXCLUDED.tier"),
          status: fragment("EXCLUDED.status"),
          current_period_end: fragment("EXCLUDED.current_period_end"),
          last_event_occurred_at:
            fragment("COALESCE(EXCLUDED.last_event_occurred_at, ?)", s.last_event_occurred_at),
          updated_at: fragment("EXCLUDED.updated_at")
        ]
      ]
    )
  end

  defp cancel_subscription(sub, data, occurred_at) do
    user = Repo.preload(sub, :user, skip_tenant_check: true).user
    # `sub` IS the user's subscription row (user_id is unique), so resolve
    # the tier from it rather than re-reading it through `get_subscription/1`.
    prev_tier = if user, do: tier(%{user | subscription: sub}), else: :free

    # Flip the user to Free at cancellation (period end per Paddle's engine).
    # `free_tier_accepted_at` is stamped only when nil so a user who had
    # originally accepted Free, upgraded, then canceled keeps the original
    # acceptance timestamp. Same transaction as the subscription write.
    stamp_free = fn locked ->
      if user && is_nil(user.free_tier_accepted_at),
        do: stamp_free_at_cancel(user, locked),
        else: :ok
    end

    case update_existing(
           sub,
           event_attrs(data, occurred_at, sub.user_id),
           occurred_at,
           stamp_free
         ) do
      # Already canceled (our refund cancel, then Paddle's own canceled; or a
      # replay): the row write is idempotent, the side effects are not.
      {:ok, %{previous: %{status: "canceled"}} = updated} ->
        {:ok, updated}

      {:ok, updated} ->
        broadcast_subscription_activated(updated.user_id, updated)

        # Force-disconnect open sockets so the next reconnect re-runs the
        # tier gate with the canceled subscription. Mirrors the behaviour
        # in subscription.updated/activated when tier or status flips.
        Engram.Auth.SessionInvalidator.disconnect_user(updated.user_id)

        if user do
          :telemetry.execute(
            [:engram, :tier_downgraded],
            %{count: 1},
            %{user_id: user.id, from: prev_tier, to: :free}
          )
        end

        {:ok, updated}

      {:error, :stale} ->
        skip_stale_event(data)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_subscription(sub, data, occurred_at) do
    attrs = event_attrs(data, occurred_at, sub.user_id)

    case update_existing(sub, attrs, occurred_at, fn _ -> :ok end) do
      {:ok, %{previous: %{tier: prev_tier, status: prev_status}} = updated} ->
        # Same broadcast event for activated/updated: the frontend
        # listener re-fetches /onboarding/status to decide what to do,
        # so plan changes and trial→active flips both push downstream UI.
        broadcast_subscription_activated(updated.user_id, updated)
        # An upgrade lifts the embed budget: the dense backfill starts now.
        _ = Engram.Workers.ReconcileEmbeddings.kick()

        # Realtime sync (and other tier-gated features) are evaluated at
        # channel-join, so an open SyncChannel keeps streaming after a
        # tier or status change. Force-disconnect when either changed so
        # the next reconnect re-runs the gate with the fresh subscription.
        if updated.tier != prev_tier or updated.status != prev_status do
          Engram.Auth.SessionInvalidator.disconnect_user(updated.user_id)
        end

        {:ok, updated}

      {:error, :stale} ->
        skip_stale_event(data)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Every write to a known row goes through here, under the owner's tenant
  # (discovered from the row, #1758). The row is re-read FOR UPDATE so two
  # deliveries for one subscription cannot both pass the occurred_at check
  # and land in the wrong order. Returns the updated row with `previous` set,
  # `{:error, :stale}`, or `{:error, changeset}`.
  defp update_existing(sub, attrs, occurred_at, in_transaction) do
    Repo.with_tenant(sub.user_id, fn ->
      locked = Repo.one!(from(s in Subscription, where: s.id == ^sub.id, lock: "FOR UPDATE"))

      if stale_event?(locked, occurred_at), do: Repo.rollback(:stale)

      case locked |> Subscription.changeset(attrs) |> Repo.update() do
        {:ok, updated} ->
          :ok = in_transaction.(locked)
          %{updated | previous: %{tier: locked.tier, status: locked.status}}

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  # The attrs every subscription event writes: status, period, the stamp (when
  # the event carries one) and the tier (unless the price_id is unknown).
  defp event_attrs(data, occurred_at, user_id) do
    base = %{status: data["status"], current_period_end: parse_period_end(data)}
    base = if occurred_at, do: Map.put(base, :last_event_occurred_at, occurred_at), else: base
    attrs_with_tier(base, data, user_id)
  end

  defp event_occurred_at(%{"occurred_at" => ts}) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp event_occurred_at(_event), do: nil

  # Equal timestamps are applied: Paddle emits subscription.updated and
  # subscription.canceled for one change with the same occurred_at.
  defp stale_event?(
         %Subscription{last_event_occurred_at: %DateTime{} = stored},
         %DateTime{} = at
       ),
       do: DateTime.compare(at, stored) == :lt

  defp stale_event?(_sub, _occurred_at), do: false

  # A skipped stale event is a permanent no-op, not an error: the caller acks
  # it 200 and marks it processed.
  defp skip_stale_event(data) do
    Logger.info(
      "paddle_webhook_stale_skipped",
      Metadata.with_category(:info, :billing, subscription_id: data["id"])
    )

    {:ok, :stale}
  end

  # The guard refused a non-created event for a different subscription than
  # the live row's. If that subscription was created after the row's newest
  # event it is the user's NEW one, ahead of its own created: answer
  # transient so Paddle retries it once the created lands, rather than ack
  # it and lose it. An older subscription's late event is a real no-op.
  defp stale_or_wait("subscription.created", data, _user_id), do: skip_stale_event(data)

  defp stale_or_wait(_type, %{"id" => sub_id} = data, user_id) do
    row = Repo.with_tenant!(user_id, fn -> Repo.get_by(Subscription, user_id: user_id) end)

    with %Subscription{paddle_subscription_id: row_sub, last_event_occurred_at: %DateTime{} = at}
         when row_sub != sub_id <- row,
         {:ok, created_at, _} <- DateTime.from_iso8601(data["created_at"] || ""),
         :gt <- DateTime.compare(created_at, at) do
      Logger.warning(
        "paddle_webhook_awaiting_created",
        Metadata.with_category(:warning, :billing, subscription_id: sub_id)
      )

      {:error, :awaiting_subscription_created}
    else
      _ -> skip_stale_event(data)
    end
  end

  defp stale_or_wait(_type, data, _user_id), do: skip_stale_event(data)

  defp error_opt(errors, field, key) do
    case errors[field] do
      {_msg, opts} when is_list(opts) -> opts[key]
      _ -> nil
    end
  end

  # The owner named in custom_data no longer exists (a hard-deleted paying
  # account: Paddle's follow-up updated/canceled still carry its user_id). No
  # retry can ever find that user, so it is acked and marked processed.
  defp skip_owner_missing(data) do
    Logger.info(
      "paddle_webhook_owner_missing_skipped",
      Metadata.with_category(:info, :billing,
        subscription_id: data["id"],
        reason: :owner_deleted
      )
    )

    {:ok, :ignored}
  end

  # Resolve the tier from the event's price_id and merge it into `base_attrs`.
  # An unknown price_id leaves the tier UNCHANGED (attrs without :tier) rather
  # than downgrading — a misconfigured price map must never strip a paying
  # user's tier — and pages via Sentry so ops fixes the mapping.
  defp attrs_with_tier(base_attrs, data, user_id) do
    case tier_from_subscription(data) do
      {:ok, tier} ->
        Map.put(base_attrs, :tier, Atom.to_string(tier))

      {:error, :unknown_price_id} ->
        _ =
          Sentry.capture_message("Unknown Paddle price_id, tier unchanged",
            extra: %{user_id: user_id, payload_keys: Map.keys(data)}
          )

        base_attrs
    end
  end

  # Webhook-side DISCOVERY: Paddle's subscription id is the only key we have
  # here, and the owner is what the read finds, so there is no tenant to scope
  # by. It runs on the app pool with no tenant set, which the
  # `subscriptions_discovery` SELECT policy answers (same shape as
  # `api_keys_discovery`). `cross_tenant/1` only silences the app-level
  # tripwire; the policy is what admits the read. The caller then writes under
  # `with_tenant(sub.user_id)`, where INSERT/UPDATE/DELETE stay tenant-scoped.
  defp get_subscription_by_paddle_id(subscription_id) do
    Repo.cross_tenant(fn ->
      Repo.one(from(s in Subscription, where: s.paddle_subscription_id == ^subscription_id))
    end)
  end

  # A Free stamp that finds no row must not roll back the cancel beside it:
  # Paddle's state is the truth, and a retry would find the same missing row.
  # Logged so the missing stamp is visible.
  defp stamp_free_at_cancel(user, sub) do
    case Engram.Onboarding.stamp_free_tier(user) do
      {:ok, _user, _won_or_lost} ->
        :ok

      {:error, :not_found} ->
        Logger.warning(
          "free stamp at cancel found no user row",
          Metadata.with_category(:warning, :billing,
            user_id: user.id,
            paddle_subscription_id: sub.paddle_subscription_id
          )
        )

        :ok
    end
  end

  # Notify the user's open browser tabs that their subscription state
  # changed server-side, so the activation overlay can hand off to the
  # next onboarding step (or settings billing UI can refresh) in
  # milliseconds rather than waiting on a polling loop. Mirrors the
  # vault_created broadcast in Engram.Vaults. Fire-and-forget: if nobody
  # is listening, Phoenix.PubSub drops it.
  defp broadcast_subscription_activated(user_id, %Subscription{} = sub) do
    # Chokepoint for every subscription mutation (created/updated/canceled),
    # called after the write commits. The row caches go FIRST: everything
    # below re-derives the tier through `get_subscription/1`. The triggers
    # evict every node on commit too, but asynchronously; this keeps the
    # writing node coherent for the reads right after (the plan snapshot
    # below, the frontend's re-fetch of /onboarding/status). The `:user` row
    # the cancel path stamps is evicted by `Onboarding.stamp_free_tier/1`.
    :ok = Engram.Cache.evict(:subscription, user_id)

    # Tier/status flips can change the onboarding gate's subscription_ok,
    # so the cached pass verdict must re-derive.
    :ok = Engram.Onboarding.GateCache.evict(user_id)

    # Same flip changes the user's tier and therefore their entire resolved
    # limit matrix — drop the cached entitlement snapshot so it re-derives.
    :ok = EntitlementCache.evict(user_id)

    # Carry the full plan snapshot so the plugin can re-gate attachments the
    # instant the subscription flips, without a follow-up fetch. `tier` stays
    # the string form (`sub.tier`, e.g. "pro") that the web frontend type and
    # existing consumers expect, so we take only the attachment limit fields
    # from plan_state (allowlist) — a future field added to plan_state/1 can't
    # silently leak into the broadcast, and this branch stays symmetric with
    # the fallback below. The attachment limit fields are the new payload.
    #
    # BUT the allowlist cuts both ways: the plugin REPLACES its plan snapshot
    # wholesale from this payload (`sync.ts` planState = parsePlanState(...)),
    # so a plan field that is missing here reads as absent/permissive, not as
    # unchanged. Anything plan_state/1 publishes that a client acts on belongs
    # in BOTH lists. (`indexed_notes_cap` is a compat shim, always nil.)
    plan_fields =
      case Engram.Accounts.get_user(user_id) do
        %Engram.Accounts.User{} = u ->
          plan_state(u)
          |> Map.take([
            :attachments_all_types,
            :blocked_extensions,
            :max_file_bytes,
            :attachment_bytes_cap,
            :indexed_notes_cap
          ])

        _ ->
          %{
            attachments_all_types: nil,
            blocked_extensions: advertised_blocked_extensions(),
            max_file_bytes: nil,
            attachment_bytes_cap: nil,
            indexed_notes_cap: nil
          }
      end

    _ =
      EngramWeb.Endpoint.broadcast(
        "user:#{user_id}",
        "subscription_activated",
        Map.merge(plan_fields, %{
          tier: sub.tier,
          status: sub.status,
          subscription_id: sub.paddle_subscription_id
        })
      )

    :ok
  end

  # ── Helpers ────────────────────────────────────────────────────

  defp extract_user_id(%{"custom_data" => %{"user_id" => id}}) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp extract_user_id(_), do: :error

  @doc """
  Resolve a tier (`:starter` | `:pro`) from a Paddle subscription data
  map. Returns `{:error, :unknown_price_id}` for unknown or missing
  prices (logged loudly via `Logger.error`) so the caller can decide what
  to do — typically: do NOT mutate the user's tier, and alert ops. This
  avoids silently downgrading a paying user to free when Paddle sends a
  price_id we don't recognize (e.g., a mis-configured env var).
  """
  @spec tier_from_subscription(map()) ::
          {:ok, :starter | :pro} | {:error, :unknown_price_id}
  def tier_from_subscription(%{"items" => [%{"price" => %{"id" => price_id}} | _]}) do
    tier_from_price_id(price_id)
  end

  def tier_from_subscription(other) do
    Logger.error(
      "paddle subscription missing items[0].price.id",
      Metadata.with_category(:error, :billing, payload_keys: Map.keys(other || %{}))
    )

    {:error, :unknown_price_id}
  end

  defp tier_from_price_id(price_id) do
    cond do
      price_id == Application.get_env(:engram, :paddle_starter_monthly_price_id) ->
        {:ok, :starter}

      price_id == Application.get_env(:engram, :paddle_starter_annual_price_id) ->
        {:ok, :starter}

      price_id == Application.get_env(:engram, :paddle_pro_monthly_price_id) ->
        {:ok, :pro}

      price_id == Application.get_env(:engram, :paddle_pro_annual_price_id) ->
        {:ok, :pro}

      true ->
        log_unknown_price_id_once(price_id)
        {:error, :unknown_price_id}
    end
  end

  # Dedupe per-process. Reconciliation iterates every Paddle sub and
  # webhook handlers run in their own request process — without this
  # guard, a misconfigured PADDLE_*_PRICE_ID env var would fire N logs
  # per reconciliation cycle (one per Paddle sub) and burn Sentry quota.
  # With the guard: one log per unique unknown price ID per process,
  # which is the actionable signal.
  defp log_unknown_price_id_once(price_id) do
    seen = Process.get(:engram_unknown_price_ids_seen, MapSet.new())

    unless MapSet.member?(seen, price_id) do
      Logger.error(
        "paddle_unknown_price_id",
        Metadata.with_category(:error, :billing,
          reason_label: :unknown_price_id,
          paddle_price_id: price_id
        )
      )

      Process.put(:engram_unknown_price_ids_seen, MapSet.put(seen, price_id))
    end
  end

  @doc """
  A Paddle subscription's current period end, truncated to seconds, as stored
  in `subscriptions.current_period_end`. nil when Paddle has no current period
  (`current_billing_period: null` on a canceled or paused subscription).
  """
  @spec parse_period_end(map()) :: DateTime.t() | nil
  def parse_period_end(%{"current_billing_period" => %{"ends_at" => ts}}) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  def parse_period_end(_), do: nil
end
