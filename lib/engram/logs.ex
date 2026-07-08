defmodule Engram.Logs do
  @moduledoc """
  Client log storage — ingest and query plugin debug logs.
  """

  import Ecto.Query

  alias Engram.Crypto.HMAC
  alias Engram.Logger.Metadata
  alias Engram.Logs.ClientLog
  alias Engram.Repo

  require Logger

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
          conn_id: entry["conn_id"] || entry[:conn_id],
          device_id: entry["device_id"] || entry[:device_id],
          created_at: now
        }
      end)

    {count, _} = Repo.insert_all(ClientLog, rows, skip_tenant_check: true)
    reemit_to_logger(user, entries)
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

  # Mirror each ingested plugin log line into the backend Logger under the
  # :client category so it flows through FireLens to CloudWatch (everything)
  # and Loki (warn+ always; info only when the client marks it diagnostic).
  # This makes both sides of a WS connection greppable by conn_id in ONE Loki
  # query, without the read-only DB bastion.
  #
  # Re-emit severity is capped at :warning (see normalize_level/1 below): a
  # client-side "error" is a bug in ONE user's plugin, not a backend failure,
  # and must never inflate engram-prod-loki-error-rate (severity="error").
  # The original client severity survives in `client_severity` metadata so
  # it's still queryable/greppable in Loki.
  defp reemit_to_logger(user, entries) do
    hashed_user = HMAC.hash_user_id(to_string(user.id))

    Enum.each(entries, fn entry ->
      try do
        raw_level = entry["level"] || entry[:level]
        level = normalize_level(raw_level)
        client_cat = entry["category"] || entry[:category] || ""
        msg = "[client:#{client_cat}] #{entry["message"] || entry[:message] || ""}"

        meta =
          Metadata.with_category(level, :client,
            conn_id: entry["conn_id"] || entry[:conn_id],
            device_id: entry["device_id"] || entry[:device_id],
            user_id: hashed_user,
            client_severity: raw_level || "info"
          )

        # Verbose diagnostic-mode entries opt into Loki per-entry even at :info.
        meta =
          if entry["diagnostic"] == true or entry[:diagnostic] == true do
            Keyword.put(meta, :loki_ship, true)
          else
            meta
          end

        Logger.log(level, msg, meta)
      rescue
        e ->
          Logger.warning(
            "client log re-emit failed: #{Exception.message(e)}",
            Engram.Logger.Metadata.with_category(:warning, :client, [])
          )
      end
    end)
  end

  # Client severity is capped at :warning on re-emit — never :error — so a
  # broken plugin loop cannot masquerade as a backend error.
  defp normalize_level("warn"), do: :warning
  defp normalize_level("error"), do: :warning
  defp normalize_level(_), do: :info
end
