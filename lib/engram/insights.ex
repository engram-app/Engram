defmodule Engram.Insights do
  @moduledoc """
  Customer insights reports (spec 2026-10-19): what users did, and above all
  what users who became paying customers did before they paid.

  `report(name, scope)` knows nothing about its caller. The operator page
  passes `:all`; a team-admin page will pass `{:org, id}` later (not built).
  Authorization lives on the route (`EngramWeb.Plugs.RequireOperator`).

  Reads `analytics_events`, the daily snapshots and the account tables
  through `Repo.maintenance()`, because a report spans every tenant. Read
  only: nothing here writes. Operator accounts and users who opted out of
  analytics are left out of every report. Rows name users by id only, and
  carry no note content, titles, paths or vault names.

  Every report aggregates in SQL, in a fixed number of queries returning a
  row per user (or per user and week) at most, never a row per event, and
  is bounded by a date window (`:days`).
  """

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Analytics.Event
  alias Engram.Billing
  alias Engram.Billing.Subscription
  alias Engram.Insights.UserDailyMetric
  alias Engram.Insights.VaultDailyMetric
  alias Engram.Onboarding.Action
  alias Engram.Repo
  alias Engram.Vaults.Vault

  @reports ~w(funnel converters path_to_paid limits surfaces ai_apps vaults retention billing churn_signals)

  # Funnel steps in order. paywall_shown and checkout_opened come from the
  # web app (`POST /api/analytics/events`).
  @steps ~w(signed_up survey_answered vault_created first_note obsidian_linked ai_connected
            first_search day2_return day7_return paywall_shown checkout_opened paid)

  # Monthly list prices in USD (pricing v3).
  @list_price %{"starter" => 7, "pro" => 14}

  @recent_days 30
  @churn_window_days 14

  @default_days 180
  @max_days 730

  @doc "The report names `report/3` accepts."
  @spec reports() :: [String.t()]
  def reports, do: @reports

  @doc """
  Build report `name` over `scope`. Only `:all` exists. A report is a plain
  map, ready to encode as JSON.

  `:days` bounds it to the last N days (default #{@default_days}, clamped to
  1..#{@max_days}): signups in the window for the per-user reports (funnel,
  converters, path_to_paid, retention), events in the window for the rest.
  `vaults` reads the latest snapshot; `churn_signals` its own 28 days.
  """
  @spec report(String.t(), :all, keyword()) :: map()
  def report(name, :all, opts \\ []) when name in @reports do
    start = since(window_days(opts[:days]))
    read(&build(name, &1, start))
  end

  @doc "`days` as a report window: default #{@default_days}, clamped to 1..#{@max_days}."
  @spec window_days(term()) :: pos_integer()
  def window_days(days) when is_integer(days), do: days |> max(1) |> min(@max_days)
  def window_days(_days), do: @default_days

  @doc "Every event and daily snapshot of one account, oldest first."
  @spec timeline(Ecto.UUID.t(), :all) :: map() | nil
  def timeline(user_id, :all) do
    read(fn repo ->
      if repo.exists?(from(u in included_users(), where: u.id == ^user_id)) do
        %{
          user_id: user_id,
          events:
            repo.all(
              from(e in Event,
                where: e.user_id == ^user_id,
                order_by: e.inserted_at,
                select: %{at: e.inserted_at, event: e.event, props: e.props}
              )
            ),
          days:
            repo.all(
              from(m in UserDailyMetric,
                where: m.user_id == ^user_id,
                order_by: m.date,
                select: m
              )
            )
            |> Enum.map(&plain(&1, [])),
          vault_days:
            repo.all(
              from(m in VaultDailyMetric,
                where: m.user_id == ^user_id,
                order_by: [m.date, m.vault_id],
                select: m
              )
            )
            |> Enum.map(&plain(&1, [:user_id]))
        }
      end
    end)
  end

  defp plain(struct, drop),
    do: struct |> Map.from_struct() |> Map.drop([:__meta__, :inserted_at, :updated_at | drop])

  defp read(fun) do
    repo = Repo.maintenance()
    Repo.cross_tenant(fn -> fun.(repo) end)
  end

  # ── Shared data ───────────────────────────────────────────────

  defp included_users do
    from(u in User,
      where: is_nil(u.deleted_at) and is_nil(u.analytics_opt_out_at) and u.role != "operator"
    )
  end

  # Raw-SQL spelling of `included_users/0`, for the queries below that read
  # only the non-tenant tables (users, analytics_events, user_daily_metrics).
  @included_sql "u.deleted_at IS NULL AND u.analytics_opt_out_at IS NULL AND u.role <> 'operator'"

  # A real payment: a 100%-off comp is discounted with a zero amount.
  @paying_sql """
  ((e.event = 'payment_completed' AND coalesce(e.props->>'amount_bucket', '0') <> '0')
   OR (e.event = 'subscription_started' AND e.props->'discounted' = 'false'::jsonb))
  """

  @tool_events ["mcp_tool_called", "mcp_tool_called_rollup"]

  # `users.created_at` is a UTC `timestamp(0)`: raw SQL compares it to a
  # naive time, an Ecto query to a second-precision DateTime.
  defp naive(%DateTime{} = dt), do: dt |> DateTime.to_naive() |> NaiveDateTime.truncate(:second)

  defp sql(repo, statement, params) do
    %{columns: columns, rows: rows} = repo.query!(statement, params, timeout: :timer.minutes(1))
    Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))
  end

  # One row per user who signed up since `start`: who they are and the first
  # time they reached each funnel step. Aggregated in SQL (one row per user,
  # whatever the event count).
  defp step_rows(repo, start) do
    evs =
      from(e in Event,
        join: u in User,
        on: u.id == e.user_id,
        where: e.inserted_at >= ^start,
        where:
          e.event in [
            "onboarding_survey_answered",
            "vault_populated",
            "plugin_linked",
            "device_connected",
            "mcp_client_connected",
            "mcp_oauth_granted",
            "search_performed",
            "surface_active",
            "paywall_shown",
            "checkout_opened",
            "payment_completed",
            "subscription_started"
          ],
        group_by: e.user_id,
        select: %{
          user_id: e.user_id,
          survey: filter(min(e.inserted_at), e.event == "onboarding_survey_answered"),
          first_note: filter(min(e.inserted_at), e.event == "vault_populated"),
          obsidian: filter(min(e.inserted_at), e.event in ["plugin_linked", "device_connected"]),
          ai:
            filter(min(e.inserted_at), e.event in ["mcp_client_connected", "mcp_oauth_granted"]),
          search:
            filter(
              min(e.inserted_at),
              e.event == "search_performed" and
                fragment("(?->>'status') IS DISTINCT FROM 'refused'", e.props)
            ),
          day2:
            filter(
              min(e.inserted_at),
              e.event == "surface_active" and
                fragment(
                  "(? AT TIME ZONE 'UTC')::date - ?::date >= 1",
                  e.inserted_at,
                  u.created_at
                )
            ),
          day7:
            filter(
              min(e.inserted_at),
              e.event == "surface_active" and
                fragment(
                  "(? AT TIME ZONE 'UTC')::date - ?::date >= 7",
                  e.inserted_at,
                  u.created_at
                )
            ),
          paywall: filter(min(e.inserted_at), e.event == "paywall_shown"),
          checkout: filter(min(e.inserted_at), e.event == "checkout_opened"),
          paid:
            filter(
              min(e.inserted_at),
              fragment(
                "((? = 'payment_completed' AND coalesce(?->>'amount_bucket', '0') <> '0') OR (? = 'subscription_started' AND ?->'discounted' = 'false'::jsonb))",
                e.event,
                e.props,
                e.event,
                e.props
              )
            )
        }
      )

    vaults =
      from(v in Vault, group_by: v.user_id, select: %{user_id: v.user_id, at: min(v.created_at)})

    actions =
      from(a in Action,
        where: a.action in ["plugin_connected", "ai_connected"],
        group_by: a.user_id,
        select: %{
          user_id: a.user_id,
          plugin: filter(min(a.inserted_at), a.action == "plugin_connected"),
          ai: filter(min(a.inserted_at), a.action == "ai_connected")
        }
      )

    from(u in included_users(),
      where: u.created_at >= ^DateTime.truncate(start, :second),
      left_join: e in subquery(evs),
      on: e.user_id == u.id,
      left_join: v in subquery(vaults),
      on: v.user_id == u.id,
      left_join: a in subquery(actions),
      on: a.user_id == u.id,
      order_by: u.created_at,
      select: %{
        id: u.id,
        created_at: u.created_at,
        signup_source: fragment("?->>'signup_source'", u.onboarding_profile),
        e: e,
        vault_at: v.at,
        plugin_at: a.plugin,
        ai_at: a.ai
      }
    )
    |> repo.all()
    |> Enum.map(&with_steps/1)
  end

  defp with_steps(%{e: e} = row) do
    e = e || %{}
    signup = to_utc(row.created_at)

    steps = %{
      "signed_up" => signup,
      "survey_answered" => to_utc(e[:survey]),
      "vault_created" => to_utc(row.vault_at),
      "first_note" => to_utc(e[:first_note]),
      "obsidian_linked" => earliest([to_utc(row.plugin_at), to_utc(e[:obsidian])]),
      "ai_connected" => earliest([to_utc(row.ai_at), to_utc(e[:ai])]),
      "first_search" => to_utc(e[:search]),
      "day2_return" => to_utc(e[:day2]),
      "day7_return" => to_utc(e[:day7]),
      "paywall_shown" => to_utc(e[:paywall]),
      "checkout_opened" => to_utc(e[:checkout]),
      "paid" => to_utc(e[:paid])
    }

    %{id: row.id, created_at: signup, signup_source: row.signup_source, steps: steps}
  end

  defp earliest(times) do
    case Enum.reject(times, &is_nil/1) do
      [] -> nil
      list -> Enum.min(list, DateTime)
    end
  end

  defp to_utc(nil), do: nil
  defp to_utc(%DateTime{} = dt), do: dt
  defp to_utc(%NaiveDateTime{} = dt), do: DateTime.from_naive!(dt, "Etc/UTC")

  defp week(%DateTime{} = dt), do: dt |> DateTime.to_date() |> Date.beginning_of_week()

  defp source(%{signup_source: own}, attributed), do: own || attributed || "direct"

  # The last signup attribution of each user signed up since `start`.
  defp attribution(repo, start) do
    ids = from(u in included_users(), select: u.id)

    from(e in Event,
      where: e.user_id in subquery(ids),
      where: e.event == "signup_attributed" and e.inserted_at >= ^start,
      distinct: e.user_id,
      order_by: [e.user_id, desc: e.inserted_at],
      select:
        {e.user_id,
         fragment(
           "coalesce(?->>'utm_source', ?->>'via', ?->>'referrer_domain')",
           e.props,
           e.props,
           e.props
         )}
    )
    |> repo.all()
    |> Map.new()
  end

  defp median([]), do: nil

  defp median(list) do
    sorted = Enum.sort(list)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, mid),
      else: (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
  end

  defp pct(_part, 0), do: nil
  defp pct(part, whole), do: Float.round(part * 100 / whole, 1)

  defp hours(from, to), do: Float.round(DateTime.diff(to, from) / 3600, 1)

  defp since(days), do: DateTime.add(DateTime.utc_now(), -days, :day)

  defp later(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)

  # ── Reports ───────────────────────────────────────────────────

  defp build("funnel", repo, start) do
    users = step_rows(repo, start)
    sources = attribution(repo, start)

    %{
      steps: funnel_steps(Enum.map(users, & &1.steps)),
      by_week:
        users
        |> Enum.group_by(&week(&1.created_at))
        |> Enum.sort_by(&elem(&1, 0), Date)
        |> Enum.map(fn {week, us} -> %{week: week, counts: step_counts(us)} end),
      by_source:
        users
        |> Enum.group_by(&source(&1, sources[&1.id]))
        |> Enum.sort()
        |> Enum.map(fn {src, us} -> %{source: src, counts: step_counts(us)} end)
    }
  end

  # Each payer's state the day before paying, against every user who had not
  # paid by the same tenure (peers). One statement: the payer x user pairs and
  # their states are built and aggregated in SQL.
  #
  # ponytail: O(payers x users) pairs, each a lateral index scan, all in
  # Postgres. Fine at thousands of users; precompute per-user daily states
  # when payers x users outgrows a request.
  defp build("converters", repo, start) do
    rows =
      sql(
        repo,
        """
        WITH included AS (
          SELECT u.id, u.created_at AT TIME ZONE 'UTC' AS created_at FROM users u
          WHERE #{@included_sql} AND u.created_at >= $1
        ),
        paid AS (
          SELECT e.user_id, min(e.inserted_at) AS paid_at
          FROM analytics_events e JOIN included i ON i.id = e.user_id
          WHERE e.inserted_at >= $2 AND #{@paying_sql}
          GROUP BY e.user_id
        ),
        payers AS (
          SELECT i.id AS payer_id, p.paid_at,
                 (p.paid_at AT TIME ZONE 'UTC')::date - (i.created_at AT TIME ZONE 'UTC')::date AS tenure
          FROM included i JOIN paid p ON p.user_id = i.id
        ),
        subjects AS (
          SELECT y.payer_id, y.payer_id AS user_id, y.paid_at AS cutoff, true AS mine FROM payers y
          UNION ALL
          SELECT y.payer_id, i.id, c.cutoff, false
          FROM payers y
          JOIN included i ON i.id <> y.payer_id
          CROSS JOIN LATERAL (SELECT i.created_at + make_interval(days => y.tenure) AS cutoff) c
          LEFT JOIN paid p ON p.user_id = i.id
          WHERE c.cutoff <= now() AND (p.paid_at IS NULL OR p.paid_at > c.cutoff)
        ),
        states AS (
          SELECT s.payer_id, s.mine, m.notes, m.vault_count, m.obsidian_devices,
                 m.mcp_client_count AS ai_apps, ev.tools_used, ev.limits_hit, ev.days_active
          FROM subjects s
          LEFT JOIN user_daily_metrics m
            ON m.user_id = s.user_id AND m.captured_at IS NOT NULL
           AND m.date = (s.cutoff AT TIME ZONE 'UTC')::date - 1
          CROSS JOIN LATERAL (
            SELECT
              count(DISTINCT e.props->>'tool') FILTER (WHERE e.event = ANY($3)) AS tools_used,
              count(*) FILTER (WHERE e.event = 'limit_hit') AS limits_hit,
              count(DISTINCT (e.inserted_at AT TIME ZONE 'UTC')::date)
                FILTER (WHERE e.event = 'surface_active') AS days_active
            FROM analytics_events e
            WHERE e.user_id = s.user_id AND e.inserted_at >= $2 AND e.inserted_at < s.cutoff
              AND (e.event = ANY($3) OR e.event IN ('limit_hit', 'surface_active'))
          ) ev
        )
        SELECT y.payer_id, y.tenure,
          max(s.notes) FILTER (WHERE s.mine) AS notes,
          max(s.vault_count) FILTER (WHERE s.mine) AS vault_count,
          max(s.obsidian_devices) FILTER (WHERE s.mine) AS obsidian_devices,
          max(s.ai_apps) FILTER (WHERE s.mine) AS ai_apps,
          max(s.tools_used) FILTER (WHERE s.mine) AS tools_used,
          max(s.limits_hit) FILTER (WHERE s.mine) AS limits_hit,
          max(s.days_active) FILTER (WHERE s.mine) AS days_active,
          count(*) FILTER (WHERE NOT s.mine) AS peers,
          percentile_cont(0.5) WITHIN GROUP (ORDER BY s.notes) FILTER (WHERE NOT s.mine) AS p_notes,
          percentile_cont(0.5) WITHIN GROUP (ORDER BY s.vault_count) FILTER (WHERE NOT s.mine) AS p_vault_count,
          percentile_cont(0.5) WITHIN GROUP (ORDER BY s.obsidian_devices) FILTER (WHERE NOT s.mine) AS p_obsidian_devices,
          percentile_cont(0.5) WITHIN GROUP (ORDER BY s.ai_apps) FILTER (WHERE NOT s.mine) AS p_ai_apps,
          percentile_cont(0.5) WITHIN GROUP (ORDER BY s.tools_used) FILTER (WHERE NOT s.mine) AS p_tools_used,
          percentile_cont(0.5) WITHIN GROUP (ORDER BY s.limits_hit) FILTER (WHERE NOT s.mine) AS p_limits_hit,
          percentile_cont(0.5) WITHIN GROUP (ORDER BY s.days_active) FILTER (WHERE NOT s.mine) AS p_days_active
        FROM payers y JOIN states s ON s.payer_id = y.payer_id
        GROUP BY y.payer_id, y.tenure, y.paid_at
        ORDER BY y.paid_at
        """,
        [naive(start), start, @tool_events]
      )

    keys = ~w(notes vault_count obsidian_devices ai_apps tools_used limits_hit days_active)a

    %{
      converters:
        Enum.map(rows, fn r ->
          %{
            user_id: Ecto.UUID.cast!(r["payer_id"]),
            tenure_days: r["tenure"],
            before_paying: Map.new(keys, &{&1, r["#{&1}"]}),
            peers: r["peers"],
            peers_median: Map.new(keys, &{&1, r["p_#{&1}"]})
          }
        end)
    }
  end

  defp build("path_to_paid", repo, start) do
    %{
      paths:
        for %{steps: %{"paid" => paid_at} = steps} = u <- step_rows(repo, start),
            paid_at != nil do
          path =
            steps
            |> Enum.reject(fn {step, at} -> is_nil(at) or step == "paid" end)
            |> Enum.filter(fn {_step, at} -> DateTime.compare(at, paid_at) != :gt end)
            |> Enum.sort_by(&elem(&1, 1), DateTime)
            |> Enum.map(fn {step, at} -> %{step: step, at: at} end)

          %{user_id: u.id, paid_at: paid_at, steps: path ++ [%{step: "paid", at: paid_at}]}
        end
    }
  end

  # Each user's first hit of each limit in the window, and what followed:
  # paid after it (upgraded), active in the last #{@churn_window_days} days
  # (stayed), or neither (churned).
  defp build("limits", repo, start) do
    rows =
      sql(
        repo,
        """
        WITH included AS (SELECT u.id FROM users u WHERE #{@included_sql}),
        hits AS (
          SELECT e.props->>'limit_key' AS limit_key, e.user_id, min(e.inserted_at) AS hit_at
          FROM analytics_events e JOIN included i ON i.id = e.user_id
          WHERE e.event = 'limit_hit' AND e.inserted_at >= $1
          GROUP BY 1, 2
        ),
        paid AS (
          SELECT e.user_id, min(e.inserted_at) AS paid_at
          FROM analytics_events e
          WHERE e.user_id IN (SELECT user_id FROM hits) AND e.inserted_at >= $1 AND #{@paying_sql}
          GROUP BY e.user_id
        ),
        outcomes AS (
          SELECT h.limit_key,
            CASE
              WHEN p.paid_at > h.hit_at THEN 'upgraded'
              WHEN EXISTS (
                SELECT 1 FROM analytics_events a
                WHERE a.user_id = h.user_id AND a.event = 'surface_active' AND a.inserted_at >= $2
              ) THEN 'stayed'
              ELSE 'churned'
            END AS outcome
          FROM hits h LEFT JOIN paid p ON p.user_id = h.user_id
        )
        SELECT limit_key,
          count(*) AS users,
          count(*) FILTER (WHERE outcome = 'upgraded') AS upgraded,
          count(*) FILTER (WHERE outcome = 'stayed') AS stayed,
          count(*) FILTER (WHERE outcome = 'churned') AS churned
        FROM outcomes GROUP BY limit_key ORDER BY users DESC
        """,
        [start, since(@churn_window_days)]
      )

    %{
      limits: Enum.map(rows, &Map.take(&1, ~w(limit_key users upgraded stayed churned)))
    }
  end

  defp build("surfaces", repo, start) do
    from_at = later(start, since(@recent_days))

    by_day =
      sql(
        repo,
        """
        SELECT (e.inserted_at AT TIME ZONE 'UTC')::date AS date, e.props->>'surface' AS surface,
               count(DISTINCT e.user_id) AS users
        FROM analytics_events e JOIN users u ON u.id = e.user_id
        WHERE #{@included_sql} AND e.inserted_at >= $1
          AND e.props->>'surface' IS NOT NULL AND e.props->>'surface' <> 'welcome'
        GROUP BY 1, 2
        """,
        [from_at]
      )

    mix =
      sql(
        repo,
        """
        SELECT mix, count(*) AS users FROM (
          SELECT string_agg(DISTINCT e.props->>'surface', '+' ORDER BY e.props->>'surface') AS mix
          FROM analytics_events e JOIN users u ON u.id = e.user_id
          WHERE #{@included_sql} AND e.inserted_at >= $1
            AND e.props->>'surface' IS NOT NULL AND e.props->>'surface' <> 'welcome'
          GROUP BY e.user_id
        ) per_user
        GROUP BY mix ORDER BY users DESC
        """,
        [from_at]
      )

    %{
      by_day:
        by_day
        |> Enum.group_by(& &1["date"])
        |> Enum.sort_by(&elem(&1, 0), Date)
        |> Enum.map(fn {date, list} ->
          list |> Map.new(&{&1["surface"], &1["users"]}) |> Map.put("date", date)
        end),
      mix: Enum.map(mix, &%{mix: &1["mix"], users: &1["users"]})
    }
  end

  defp build("ai_apps", repo, start) do
    included = "JOIN users u ON u.id = e.user_id WHERE #{@included_sql} AND e.inserted_at >= $1"

    clients =
      sql(
        repo,
        """
        SELECT e.props->>'client' AS client, count(DISTINCT e.user_id) AS users
        FROM analytics_events e #{included} AND e.event = 'mcp_client_connected'
        GROUP BY 1 ORDER BY users DESC
        """,
        [start]
      )

    per_user =
      sql(
        repo,
        """
        SELECT clients, count(*) AS users FROM (
          SELECT count(DISTINCT e.props->>'client') AS clients
          FROM analytics_events e #{included} AND e.event = 'mcp_client_connected'
          GROUP BY e.user_id
        ) c GROUP BY clients ORDER BY clients
        """,
        [start]
      )

    volume = fn label ->
      key = Atom.to_string(label)

      sql(
        repo,
        """
        SELECT e.props->>'#{key}' AS key,
               sum(coalesce((e.props->>'calls')::bigint, 1))::bigint AS calls,
               sum(coalesce((e.props->>'errors')::bigint, 0))::bigint AS errors
        FROM analytics_events e #{included} AND e.event = ANY($2)
        GROUP BY 1 ORDER BY calls DESC
        """,
        [start, @tool_events]
      )
      |> Enum.map(fn %{"key" => k, "calls" => calls, "errors" => errors} ->
        %{label => k, calls: calls, errors: errors, error_pct: pct(errors, calls)}
      end)
    end

    %{
      clients: Enum.map(clients, &%{client: &1["client"], users: &1["users"]}),
      clients_per_user: Enum.map(per_user, &%{clients: &1["clients"], users: &1["users"]}),
      tools: volume.(:tool),
      by_client: volume.(:client)
    }
  end

  defp build("vaults", repo, start) do
    latest = repo.one(from(m in VaultDailyMetric, select: max(m.date)))

    growth_from =
      Enum.max([Date.add(Date.utc_today(), -@recent_days), DateTime.to_date(start)], Date)

    stats =
      if latest do
        sql(
          repo,
          """
          SELECT count(*) AS vaults, #{distribution_sql(~w(notes note_bytes attachments attachment_bytes))}
          FROM vault_daily_metrics m JOIN users u ON u.id = m.user_id
          WHERE #{@included_sql} AND m.date = $1
          """,
          [latest]
        )
        |> hd()
      else
        %{"vaults" => 0}
      end

    per_user =
      if latest do
        sql(
          repo,
          """
          SELECT vaults, count(*) AS users FROM (
            SELECT count(*) AS vaults FROM vault_daily_metrics m JOIN users u ON u.id = m.user_id
            WHERE #{@included_sql} AND m.date = $1 GROUP BY m.user_id
          ) c GROUP BY vaults ORDER BY vaults
          """,
          [latest]
        )
      else
        []
      end

    ids = from(u in included_users(), select: u.id)

    %{
      date: latest,
      vaults: stats["vaults"],
      notes: distribution(stats, "notes"),
      note_bytes: distribution(stats, "note_bytes"),
      attachments: distribution(stats, "attachments"),
      attachment_bytes: distribution(stats, "attachment_bytes"),
      vaults_per_user: Enum.map(per_user, &%{vaults: &1["vaults"], users: &1["users"]}),
      growth:
        repo.all(
          from(m in VaultDailyMetric,
            where: m.date >= ^growth_from and m.user_id in subquery(ids),
            group_by: m.date,
            order_by: m.date,
            select: %{
              date: m.date,
              vaults: count(),
              notes: type(sum(m.notes), :integer),
              note_bytes: type(sum(m.note_bytes), :integer)
            }
          )
        )
    }
  end

  defp build("retention", repo, start) do
    users = step_rows(repo, start)

    first_surface =
      sql(
        repo,
        """
        SELECT DISTINCT ON (e.user_id) e.user_id, e.props->>'surface' AS surface
        FROM analytics_events e JOIN users u ON u.id = e.user_id
        WHERE #{@included_sql} AND u.created_at >= $1 AND e.inserted_at >= $2
          AND e.event = 'surface_active'
        ORDER BY e.user_id, e.inserted_at
        """,
        [naive(start), start]
      )
      |> Map.new(&{Ecto.UUID.cast!(&1["user_id"]), &1["surface"]})

    # One row per user and week active, not per event.
    weeks_active =
      sql(
        repo,
        """
        SELECT DISTINCT e.user_id,
               date_trunc('week', e.inserted_at AT TIME ZONE 'UTC')::date AS week
        FROM analytics_events e JOIN users u ON u.id = e.user_id
        WHERE #{@included_sql} AND u.created_at >= $1 AND e.inserted_at >= $2
          AND e.event = 'surface_active'
        """,
        [naive(start), start]
      )
      |> Enum.group_by(&Ecto.UUID.cast!(&1["user_id"]), & &1["week"])

    splits = [
      {"all", fn _u -> "all" end},
      {"first_surface", &(first_surface[&1.id] || "none")},
      {"ai_connected", &if(&1.steps["ai_connected"], do: "yes", else: "no")}
    ]

    %{
      cohorts:
        for {split, key_fun} <- splits,
            {{value, cohort}, members} <-
              Enum.group_by(users, &{key_fun.(&1), week(&1.created_at)}) do
          %{
            split: split,
            value: value,
            cohort: cohort,
            size: length(members),
            weeks: retention_weeks(cohort, members, weeks_active)
          }
        end
        |> Enum.sort_by(&{&1.split, &1.value, Date.to_iso8601(&1.cohort)})
    }
  end

  defp build("billing", repo, start) do
    ids = from(u in included_users(), select: u.id)

    counts =
      repo.all(
        from(e in Event,
          where: e.user_id in subquery(ids) and e.inserted_at >= ^start,
          where:
            e.event in [
              "subscription_trial_started",
              "subscription_changed",
              "subscription_canceled",
              "subscription_cancel_reason",
              "refund_issued"
            ],
          group_by: [
            e.event,
            fragment("?->>'kind'", e.props),
            fragment("?->>'reason'", e.props)
          ],
          select: {
            e.event,
            fragment("?->>'kind'", e.props),
            fragment("?->>'reason'", e.props),
            count()
          }
        )
      )

    count_where = fn pred ->
      counts |> Enum.filter(pred) |> Enum.map(&elem(&1, 3)) |> Enum.sum()
    end

    count_event = fn name -> count_where.(&(elem(&1, 0) == name)) end
    count_kind = fn kind -> count_where.(&match?({"subscription_changed", ^kind, _, _}, &1)) end

    # Entitled subscriptions, split by whether their user has ever made a
    # real payment (any time: an annual payer may have paid before the window).
    entitled =
      from(s in Subscription,
        where: s.user_id in subquery(ids) and s.status in ^Billing.entitled_statuses(),
        where: s.tier in ["starter", "pro"],
        select: %{
          tier: s.tier,
          paid:
            fragment(
              "EXISTS (SELECT 1 FROM analytics_events e WHERE e.user_id = ? AND ((e.event = 'payment_completed' AND coalesce(e.props->>'amount_bucket', '0') <> '0') OR (e.event = 'subscription_started' AND e.props->'discounted' = 'false'::jsonb)))",
              s.user_id
            )
        }
      )

    subs =
      repo.all(
        from(s in subquery(entitled),
          group_by: [s.tier, s.paid],
          select: {s.tier, s.paid, count()}
        )
      )

    paid = for {tier, true, n} <- subs, into: %{}, do: {tier, n}

    %{
      trials: count_event.("subscription_trial_started"),
      upgrades: count_kind.("upgrade"),
      downgrades: count_kind.("downgrade"),
      cancels_scheduled: count_kind.("cancel_scheduled"),
      cancels: count_event.("subscription_canceled"),
      cancel_reasons:
        for(
          {"subscription_cancel_reason", _kind, reason, n} <- counts,
          reduce: %{},
          do: (acc -> Map.update(acc, reason, n, &(&1 + n)))
        ),
      refunds: count_event.("refund_issued"),
      paying_subscriptions: paid,
      # Entitled, but no real payment on record: comped (100%-off) accounts,
      # trials, and subscriptions older than the event log.
      unverified_subscriptions: Enum.sum(for {_tier, false, n} <- subs, do: n),
      mrr_usd: Enum.sum(for {tier, n} <- paid, do: @list_price[tier] * n)
    }
  end

  defp build("churn_signals", repo, _start) do
    rows =
      sql(
        repo,
        """
        SELECT e.user_id,
          count(DISTINCT (e.inserted_at AT TIME ZONE 'UTC')::date)
            FILTER (WHERE e.event = 'surface_active' AND e.inserted_at >= $1) AS days_now,
          count(DISTINCT (e.inserted_at AT TIME ZONE 'UTC')::date)
            FILTER (WHERE e.event = 'surface_active' AND e.inserted_at < $1) AS days_before,
          coalesce(bool_or(e.event = 'device_disconnected' AND e.inserted_at >= $1), false) AS device,
          coalesce(bool_or(e.event = 'mcp_client_disconnected' AND e.inserted_at >= $1), false) AS ai
        FROM analytics_events e JOIN users u ON u.id = e.user_id
        WHERE #{@included_sql} AND e.inserted_at >= $2
          AND e.event IN ('surface_active', 'device_disconnected', 'mcp_client_disconnected')
        GROUP BY e.user_id
        """,
        [since(@churn_window_days), since(2 * @churn_window_days)]
      )

    users =
      for r <- rows,
          signals = churn_signals(r),
          signals != [],
          do: %{user_id: Ecto.UUID.cast!(r["user_id"]), signals: signals}

    %{users: users}
  end

  # ── Report helpers ────────────────────────────────────────────

  # The gap to a step is from the last earlier step the same user reached,
  # so a skipped step (no survey, say) does not drop the user from it.
  defp funnel_steps(all_times) do
    signups = length(all_times)

    @steps
    |> Enum.with_index()
    |> Enum.map(fn {step, i} ->
      reached = Enum.filter(all_times, & &1[step])
      earlier = Enum.take(@steps, i)

      gaps =
        for t <- reached,
            prev = earlier |> Enum.reverse() |> Enum.find(&t[&1]),
            prev != nil,
            do: hours(t[prev], t[step])

      %{
        step: step,
        users: length(reached),
        pct: pct(length(reached), signups),
        median_hours_from_previous: median(gaps)
      }
    end)
  end

  defp step_counts(users) do
    Map.new(@steps, fn step -> {step, Enum.count(users, & &1.steps[step])} end)
  end

  # Median (Postgres `percentile_cont`), p90 (the value at index
  # floor(n * 0.9) of the sorted list), max and total of each column, in SQL.
  defp distribution_sql(columns) do
    Enum.map_join(columns, ",\n", fn c ->
      """
      percentile_cont(0.5) WITHIN GROUP (ORDER BY m.#{c}) AS #{c}_median,
      (array_agg(m.#{c} ORDER BY m.#{c}))[floor(count(*) * 0.9)::int + 1] AS #{c}_p90,
      max(m.#{c}) AS #{c}_max,
      coalesce(sum(m.#{c}), 0)::bigint AS #{c}_total
      """
    end)
  end

  defp distribution(%{"vaults" => 0}, _column), do: %{median: nil, p90: nil, max: nil, total: 0}

  defp distribution(stats, column) do
    get = &Map.fetch!(stats, "#{column}_#{&1}")
    %{median: get.("median"), p90: get.("p90"), max: get.("max"), total: get.("total")}
  end

  # Share of the cohort active in each week since signup, up to this week.
  defp retention_weeks(cohort, members, weeks_active) do
    this_week = Date.beginning_of_week(Date.utc_today())
    n = div(Date.diff(this_week, cohort), 7)

    for offset <- 0..min(n, 12) do
      week = Date.add(cohort, offset * 7)
      active = Enum.count(members, &(week in Map.get(weeks_active, &1.id, [])))
      pct(active, length(members))
    end
  end

  defp churn_signals(r) do
    [
      {r["days_before"] >= 2 and r["days_now"] * 2 < r["days_before"], "activity_dropped"},
      {r["device"], "device_disconnected"},
      {r["ai"], "ai_app_disconnected"}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end
end
