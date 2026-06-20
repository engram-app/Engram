defmodule EngramWeb.LogsController do
  use EngramWeb, :controller
  use OpenApiSpex.ControllerSpecs
  alias EngramWeb.Schemas

  alias Engram.Logs

  operation(:ingest,
    operation_id: "logs-ingest",
    summary: "Ingest client logs",
    "x-internal": true,
    tags: ["Logs"],
    request_body: {"Log lines", "application/json", Schemas.LogIngestRequest, required: true},
    responses: [ok: {"Persisted count", "application/json", Schemas.LogIngestResponse}]
  )

  def ingest(conn, %{"logs" => logs}) when is_list(logs) do
    user = conn.assigns.current_user
    {:ok, count} = Logs.insert_logs(user, logs)
    json(conn, %{ok: true, count: count})
  end

  def ingest(conn, _params), do: json(conn, %{ok: true, count: 0})

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

    opts =
      []
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
