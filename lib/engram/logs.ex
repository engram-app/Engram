defmodule Engram.Logs do
  @moduledoc """
  Client log storage — ingest and query plugin debug logs.
  """

  import Ecto.Query

  alias Engram.Logs.ClientLog
  alias Engram.Repo

  @max_query_limit 1000
  @default_limit 200

  @doc """
  Insert a batch of log entries for a user.
  Returns {:ok, count} with the number of entries inserted.
  """
  def insert_logs(_user, []), do: {:ok, 0}

  def insert_logs(user, entries) when is_list(entries) do
    now = DateTime.utc_now(:second)

    rows =
      Enum.map(entries, fn entry ->
        ts = parse_ts(entry["ts"] || entry[:ts]) || now

        %{
          user_id: user.id,
          ts: ts,
          level: entry["level"] || entry[:level] || "info",
          category: entry["category"] || entry[:category] || "",
          message: entry["message"] || entry[:message] || "",
          stack: entry["stack"] || entry[:stack],
          plugin_version: entry["plugin_version"] || entry[:plugin_version] || "",
          platform: entry["platform"] || entry[:platform] || "",
          created_at: now
        }
      end)

    {count, _} = Repo.insert_all(ClientLog, rows, skip_tenant_check: true)
    {:ok, count}
  end

  @doc """
  Query logs for a user. Supports filtering by level, category, since timestamp.
  Returns newest first, up to `limit` entries.
  """
  def list_logs(user, opts \\ []) do
    level = Keyword.get(opts, :level)
    category = Keyword.get(opts, :category)
    since = Keyword.get(opts, :since)
    limit = Keyword.get(opts, :limit, @default_limit) |> min(@max_query_limit) |> max(1)

    query =
      from(l in ClientLog,
        where: l.user_id == ^user.id,
        order_by: [desc: l.ts],
        limit: ^limit
      )

    query = if level, do: where(query, [l], l.level == ^level), else: query
    query = if category, do: where(query, [l], l.category == ^category), else: query
    query = if since, do: where(query, [l], l.ts > ^since), else: query

    {:ok, Repo.all(query, skip_tenant_check: true)}
  end

  defp parse_ts(nil), do: nil

  defp parse_ts(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp parse_ts(_), do: nil
end
