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

  # Write-path bounds, kept beside the read bound above so the asymmetry is
  # visible: the read path has been capped since it was written, the write path
  # was not capped at all. Before this, the only ceiling on `POST /api/logs` was
  # the global 11 MB `Plug.Parsers` body limit, so one authenticated request
  # could insert a single ~11 MB `message` or ~100k rows in one `insert_all`.
  #
  # Not a security hole (authenticated, per-user, rate-limited) — a storage and
  # observability-cost one, since every entry is ALSO re-emitted into the server
  # log pipeline and billed again downstream.
  @max_batch_entries 1000

  # Generous for a diagnostics pipe: a real client line is a few hundred chars,
  # and a stack is the one field with a legitimate reason to be long.
  @max_message_chars 8_000
  @max_stack_chars 16_000

  # Identifier-ish fields. `device_id`/`conn_id` are UUID-shaped, so 128 is
  # already far past anything legitimate; the rest are short enums/versions.
  @max_short_chars 128

  @doc """
  Insert a batch of log entries for a user.
  Returns {:ok, count} with the number of entries inserted.
  """
  def insert_logs(_user, []), do: {:ok, 0}

  def insert_logs(user, entries) when is_list(entries) do
    now = DateTime.utc_now(:second)

    {kept, dropped} = take_bounded(entries)

    if dropped > 0 do
      Logger.warning(
        "client log batch truncated: kept #{@max_batch_entries}, dropped #{dropped}",
        Metadata.with_category(:warning, :client, dropped: dropped)
      )
    end

    # Bound ONCE, up front, then use the bounded entries for both the DB write
    # and the Logger re-emit. Truncating only on the way to Postgres would still
    # ship the full oversized message to FireLens -> Loki/CloudWatch, i.e. pay
    # for it twice.
    bounded = Enum.map(kept, &bound_entry(&1, now))

    rows =
      Enum.map(bounded, fn e ->
        %{
          user_id: user.id,
          ts: e.ts,
          level: e.level,
          category: e.category,
          message: e.message,
          stack: e.stack,
          plugin_version: e.plugin_version,
          platform: e.platform,
          conn_id: e.conn_id,
          device_id: e.device_id,
          created_at: now
        }
      end)

    {count, _} = Repo.insert_all(ClientLog, rows, skip_tenant_check: true)
    reemit_to_logger(user, bounded)
    {:ok, count}
  end

  # Truncate rather than reject. This is a diagnostics pipe: a 413 on a log push
  # loses the very breadcrumbs someone is trying to collect, and the client
  # cannot retry into a smaller shape.
  defp take_bounded(entries) do
    case Enum.split(entries, @max_batch_entries) do
      {kept, []} -> {kept, 0}
      {kept, rest} -> {kept, length(rest)}
    end
  end

  defp bound_entry(entry, now) do
    %{
      ts: parse_ts(get(entry, "ts", :ts)) || now,
      level: get(entry, "level", :level) |> default("info") |> clamp(@max_short_chars),
      category: get(entry, "category", :category) |> default("") |> clamp(@max_short_chars),
      message: get(entry, "message", :message) |> default("") |> clamp(@max_message_chars),
      stack: get(entry, "stack", :stack) |> clamp(@max_stack_chars),
      plugin_version:
        get(entry, "plugin_version", :plugin_version) |> default("") |> clamp(@max_short_chars),
      platform: get(entry, "platform", :platform) |> default("") |> clamp(@max_short_chars),
      conn_id: get(entry, "conn_id", :conn_id) |> clamp(@max_short_chars),
      device_id: get(entry, "device_id", :device_id) |> clamp(@max_short_chars),
      diagnostic: get(entry, "diagnostic", :diagnostic) == true
    }
  end

  # Entries arrive string-keyed as JSON in prod, but atom-keyed from internal
  # callers and tests — the original code checked both for every field, so this
  # keeps doing that. Both keys are passed explicitly rather than deriving one
  # from the other: `String.to_existing_atom/1` would raise for any key whose
  # atom is not already in the table, which is a needless runtime cliff on the
  # ingest path.
  defp get(entry, string_key, atom_key), do: entry[string_key] || entry[atom_key]

  defp default(nil, fallback), do: fallback
  defp default(value, _fallback), do: value

  # Only strings are clamped. A non-binary would fail at the DB anyway, and
  # silently coercing it here would hide a malformed client rather than surface
  # it. Counts characters, not bytes, so a multi-byte codepoint is never split.
  defp clamp(value, max) when is_binary(value) do
    if String.length(value) > max, do: String.slice(value, 0, max), else: value
  end

  defp clamp(value, _max), do: value

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
  # Takes the BOUNDED entries built by insert_logs/2, not the raw request body,
  # so an oversized message is not shipped downstream at full size.
  defp reemit_to_logger(user, entries) do
    hashed_user = HMAC.hash_user_id(to_string(user.id))

    Enum.each(entries, fn entry ->
      try do
        level = normalize_level(entry.level)
        msg = "[client:#{entry.category}] #{entry.message}"

        meta =
          Metadata.with_category(level, :client,
            conn_id: entry.conn_id,
            device_id: entry.device_id,
            user_id: hashed_user,
            client_severity: entry.level
          )

        # Verbose diagnostic-mode entries opt into Loki per-entry even at :info.
        meta =
          if entry.diagnostic do
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
