defmodule EngramWeb.LogsController do
  use EngramWeb, :controller
  use OpenApiSpex.ControllerSpecs
  alias EngramWeb.Schemas

  alias Engram.Logs
  alias Engram.Logs.BudgetDrops
  alias EngramWeb.OriginDevice
  alias EngramWeb.Plugs.ClientLogsThrottle
  alias EngramWeb.RateLimiter

  # Per-device line budget (2026-10-17 prod CPU alert: ingest jumped 296 -> 8,332
  # lines per 10m). The per-request limiters bound request count, not lines,
  # and one request can carry 1,000 lines, each scrubbed, inserted and maybe
  # re-emitted.
  #
  # 500 per 10 min (was 5,000): one device's warn loop wrote 212k-260k rows a
  # day for four days in 2026-10, 56% of the table. It counts only lines that
  # are kept (`Logs.insert_logs/4` `:admit`), so info lines the SaaS filter
  # drops never spend it. Over-cap lines are counted on
  # `[:engram, :client_logs, :dropped]` with `reason: :over_budget`.
  #
  # Over budget we answer 200 and drop the batch rather than 429: the plugin's
  # remote logger re-buffers a failed batch and logs the failure into the same
  # buffer, so a 429 would turn into a retry storm of the lines we refused.
  # The 200 carries `throttled: true` and `retry_after_ms` (to the end of this
  # window) for a plugin that backs off on it. The warning for it is
  # `Engram.Logs.BudgetDrops`'s, one per device per 10 minutes. A refusal also
  # marks the caller spent, so its next requests are refused at the front of
  # the pipeline (`EngramWeb.Plugs.ClientLogsThrottle`), before auth or the DB.
  #
  # X-Device-Id is client-chosen, so a rotating id would mint a fresh device
  # budget per value; a per-user total (4 devices' worth) caps that. Requests
  # without an id share a per-user fallback device bucket.
  #
  # CI/E2E can lift the device budget via CLIENT_LOG_LINE_BUDGET_OVERRIDE
  # (CI=true only, Engram.RuntimeConfig): the harness keeps one device id per
  # run and its log oracle reads these lines.
  # ponytail: a batch that crosses the budget is dropped whole (Hammer's deny
  # carries no count to accept a partial batch); partial accept if it matters.
  @line_budget 500
  @user_budget_devices 4
  @line_window_ms ClientLogsThrottle.window_ms()

  operation(:ingest,
    operation_id: "logs-ingest",
    summary: "Ingest client logs",
    "x-internal": true,
    tags: ["Logs"],
    request_body: {"Log lines", "application/json", Schemas.LogIngestRequest, required: true},
    responses: [ok: {"Persisted count", "application/json", Schemas.LogIngestResponse}]
  )

  def ingest(conn, %{"logs" => [_ | _] = logs}) do
    user = conn.assigns.current_user
    device = OriginDevice.from_conn(conn) || "user"
    budget = Application.get_env(:engram, :client_log_line_budget_override) || @line_budget

    case Logs.insert_logs(user, logs, conn.assigns.current_vault.id,
           exhausted?: fn -> budget_spent?(user, device, budget) end,
           admit: &within_line_budget?(user, device, budget, &1)
         ) do
      {:ok, count} ->
        json(conn, %{ok: true, count: count})

      # Still a 200 (see above), but now it says so: a plugin that reads
      # `throttled` stops shipping until the window ends; an older one
      # ignores the extra keys exactly as it ignored the bare count: 0.
      {:over_budget, lines} ->
        BudgetDrops.add(user.id, device, lines)
        :ok = ClientLogsThrottle.mark_spent(conn)
        ClientLogsThrottle.throttled(conn)
    end
  end

  def ingest(conn, _params), do: json(conn, %{ok: true, count: 0})

  # Checked before any line is bounded: once a bucket is spent (Hammer counts
  # a denied increment too, so it stays spent until the window rolls), a
  # refused batch costs two ETS reads, not a scrub per line.
  defp budget_spent?(user, device, budget) do
    RateLimiter.peek(device_key(user, device), @line_window_ms, budget) == 0 or
      RateLimiter.peek(user_key(user), @line_window_ms, budget * @user_budget_devices) == 0
  end

  defp within_line_budget?(user, device, budget, lines) do
    with {:allow, _} <-
           RateLimiter.hit(device_key(user, device), @line_window_ms, budget, :client_logs, lines),
         {:allow, _} <-
           RateLimiter.hit(
             user_key(user),
             @line_window_ms,
             budget * @user_budget_devices,
             :client_logs,
             lines
           ) do
      true
    else
      {:deny, _} -> false
    end
  end

  defp device_key(user, device), do: "client_logs:#{user.id}:#{device}"
  defp user_key(user), do: "client_logs:#{user.id}"

  operation(:index,
    operation_id: "logs-list",
    summary: "List ingested logs",
    "x-internal": true,
    tags: ["Logs"],
    parameters: [
      level: [in: :query, type: :string, required: false, description: "Filter by level"],
      category: [in: :query, type: :string, required: false, description: "Filter by category"],
      since: [in: :query, type: :string, required: false, description: "ISO 8601 lower bound"],
      limit: [in: :query, type: :integer, required: false, description: "Max rows"]
    ],
    responses: [ok: {"Logs", "application/json", Schemas.LogsResponse}]
  )

  def index(conn, params) do
    user = conn.assigns.current_user

    # Scoped to the addressed vault, not just the user: a credential restricted
    # to vault A must not read vault B's lines (#1866).
    opts =
      [vault_id: conn.assigns.current_vault.id]
      |> maybe_add(:level, params["level"])
      |> maybe_add(:category, params["category"])
      |> maybe_add_since(params["since"])
      |> maybe_add_limit(params["limit"])

    {:ok, logs} = Logs.list_logs(user, opts)

    json(conn, %{
      logs: Enum.map(logs, &serialize_log/1)
    })
  end

  defp serialize_log(log) do
    %{
      id: log.id,
      ts: log.ts,
      level: log.level,
      category: log.category,
      message: log.message,
      stack: log.stack,
      plugin_version: log.plugin_version,
      platform: log.platform,
      device_id: log.device_id,
      conn_id: log.conn_id,
      forced: log.forced,
      created_at: log.created_at
    }
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_add_since(opts, nil), do: opts

  defp maybe_add_since(opts, since) do
    case DateTime.from_iso8601(since) do
      {:ok, dt, _} -> Keyword.put(opts, :since, dt)
      _ -> opts
    end
  end

  defp maybe_add_limit(opts, nil), do: opts

  defp maybe_add_limit(opts, limit) do
    case Integer.parse(limit) do
      {n, ""} -> Keyword.put(opts, :limit, n)
      _ -> opts
    end
  end
end
