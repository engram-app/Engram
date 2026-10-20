defmodule Engram.Logs do
  @moduledoc """
  Client log storage — ingest and query plugin debug logs.
  """

  import Ecto.Query

  alias Engram.Crypto.HMAC
  alias Engram.Logger.Metadata
  alias Engram.Logs.ClientLog
  alias Engram.Logs.TextScrubber
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

  # How many `diagnostic: true` entries in ONE batch may force themselves into
  # Loki. `diagnostic` is a client-controlled boolean straight off the request
  # body (`bound_entry/2`), so before the paired routing rule existed it was a
  # flag nothing read and the flood was absorbed silently. It is live now:
  # uncapped, one authenticated plugin with the dial pinned on could push
  # @max_batch_entries lines per request into a billed-on-ingest sink at the
  # PreAuthRateLimit ceiling.
  #
  # The cap is per REQUEST, which bounds the per-minute worst case to this
  # times that ceiling rather than eliminating it — a token bucket would be the
  # complete answer and is not worth a new limiter bucket for a diagnostics
  # pipe. 100 is well above a real debugging burst (the plugin flushes at 20)
  # and 10x below the batch cap. Entries past it still reach CloudWatch and the
  # DB; only the Loki copy is dropped.
  @max_diagnostic_ships 100

  # Generous for a diagnostics pipe: a real client line is a few hundred chars,
  # and a stack is the one field with a legitimate reason to be long.
  @max_message_chars 8_000
  @max_stack_chars 16_000
  # Raw input kept for scrubbing is this multiple of the stored cap.
  @scrub_headroom 4

  # Identifier-ish fields. `device_id`/`conn_id` are UUID-shaped, so 128 is
  # already far past anything legitimate; the rest are short enums/versions.
  @max_short_chars 128

  # Structured fields a client may send beside a line (`context`), each with
  # the only shape it may take. Today: the web SPA's network_error context
  # (frontend/src/api/network-context.ts), which is how a "Failed to fetch"
  # that never reached Cloudflare gets told apart (fast fail vs stall, a
  # backgrounded tab, one browser build). Anything else in `context` (a key
  # not listed, a value out of shape) is dropped: these become Loki metadata,
  # where a free-text field would be a path leak and a cardinality bomb.
  @context_fields [
    browser: {:match, ~r/\A(?:[A-Za-z][A-Za-z ]{0,30} \d{1,4}|unknown)\z/},
    went_offline: :boolean,
    attempt: {:integer, 1..10},
    elapsed_ms: {:integer, 0..3_600_000},
    error_name: {:one_of, ~w(TypeError AbortError TimeoutError NetworkError other)},
    error_message:
      {:one_of,
       [
         "Failed to fetch",
         "Load failed",
         "NetworkError when attempting to fetch resource.",
         "other"
       ]},
    visibility: {:one_of, ~w(visible hidden prerender)},
    effective_type: {:one_of, ~w(slow-2g 2g 3g 4g)}
  ]

  @doc """
  Insert a batch of log entries for a user.
  Returns {:ok, count} with the number of entries inserted.

  `vault_id` stamps the vault the request addressed, so `list_logs/2` can keep
  a credential scoped to one vault out of another vault's lines.
  """
  def insert_logs(user, entries, vault_id \\ nil)
  def insert_logs(_user, [], _vault_id), do: {:ok, 0}

  def insert_logs(user, entries, vault_id) when is_list(entries) do
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
          vault_id: vault_id,
          ts: e.ts,
          level: e.level,
          category: e.category,
          message: e.message,
          stack: e.stack,
          plugin_version: e.plugin_version,
          platform: e.platform,
          conn_id: e.conn_id,
          device_id: e.device_id,
          forced: e.forced,
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
      # Scrub BEFORE the final clamp: truncating first can cut a quoted path
      # off its closing quote, and a half path then passes every rule. The
      # raw pre-cap only bounds the scrub's work; anything past it is beyond
      # the final clamp anyway.
      message:
        get(entry, "message", :message)
        |> default("")
        |> clamp(@max_message_chars * @scrub_headroom)
        |> TextScrubber.scrub()
        |> clamp(@max_message_chars),
      stack:
        get(entry, "stack", :stack)
        |> clamp(@max_stack_chars * @scrub_headroom)
        |> TextScrubber.scrub_stack()
        |> clamp(@max_stack_chars),
      plugin_version:
        get(entry, "plugin_version", :plugin_version) |> default("") |> clamp(@max_short_chars),
      platform: get(entry, "platform", :platform) |> default("") |> clamp(@max_short_chars),
      conn_id: get(entry, "conn_id", :conn_id) |> clamp(@max_short_chars),
      device_id: get(entry, "device_id", :device_id) |> clamp(@max_short_chars),
      diagnostic: get(entry, "diagnostic", :diagnostic) == true,
      forced: get(entry, "forced", :forced) == true,
      context: bound_context(get(entry, "context", :context))
    }
  end

  # Keyword list of the allowlisted context fields that hold their declared
  # shape. The keys come from the allowlist, never from input. String-keyed
  # off the wire, atom-keyed from internal callers, as `get/3` above.
  # A generator, not `value = ...`: a bare match in a `for` is a FILTER, so a
  # `false` value was silently dropped.
  defp bound_context(context) when is_map(context) do
    for {key, shape} <- @context_fields,
        {:ok, value} <- [fetch_context(context, key)],
        context_value?(shape, value),
        do: {key, value}
  end

  defp bound_context(_context), do: []

  defp fetch_context(context, key) do
    with :error <- Map.fetch(context, Atom.to_string(key)), do: Map.fetch(context, key)
  end

  defp context_value?(:boolean, value), do: is_boolean(value)
  defp context_value?({:integer, range}, value), do: is_integer(value) and value in range
  defp context_value?({:one_of, allowed}, value), do: value in allowed
  defp context_value?({:match, regex}, value), do: is_binary(value) and value =~ regex

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
  `:since` is applied at the stored one-second resolution: rows whose second is
  at or after `since`'s second match.
  Returns newest first, up to `limit` entries.

  `:vault_id` restricts to one vault's lines. The HTTP read always passes it;
  NULL-vault (pre-#1866) rows never match.
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

    query =
      case Keyword.fetch(opts, :vault_id) do
        {:ok, vault_id} -> where(query, [l], l.vault_id == ^vault_id)
        :error -> query
      end

    query = if level, do: where(query, [l], l.level == ^level), else: query
    query = if category, do: where(query, [l], l.category == ^category), else: query

    query =
      if since do
        # `ts` is stored truncated to the second (parse_ts/1), so compare at
        # that resolution: floor `since` and use >=. A strict `ts > since` with a
        # sub-second `since` silently dropped every row logged in the same
        # second (e2e test_66). Cost: rows up to <1 s before `since` also match.
        floor = DateTime.truncate(since, :second)
        where(query, [l], l.ts >= ^floor)
      else
        query
      end

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

  # Mirror ingested plugin log lines into the backend Logger under the :client
  # category so they flow through FireLens to CloudWatch and Loki. Only lines
  # Loki takes are written (warn+, or info the client marks diagnostic): a plain
  # info line was formatted and written to stdout for every entry only to be
  # dropped by Fluent Bit's Loki route, and the row is in client_logs anyway.
  # That was most of the logging CPU during a first sync (2026-10-17: 6,344
  # info lines from one device in 20 min). Identical lines in one batch are
  # written once with a `repeat` count.
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
    {ship_ok, over} = diagnostic_budget(entries)

    if over > 0 do
      Logger.warning(
        "client diagnostic ships capped: kept #{@max_diagnostic_ships}, dropped #{over}",
        Metadata.with_category(:warning, :client, [])
      )
    end

    entries
    |> Enum.map_reduce(ship_ok, fn entry, budget ->
      {{entry, entry.diagnostic and budget > 0},
       if(entry.diagnostic, do: max(budget - 1, 0), else: budget)}
    end)
    |> elem(0)
    |> Enum.filter(fn {entry, ship?} -> ship? or normalize_level(entry.level) == :warning end)
    |> collapse_repeats()
    |> Enum.each(fn {{entry, ship?}, repeat} ->
      try do
        level = normalize_level(entry.level)
        msg = "[client:#{entry.category}] #{entry.message}"

        meta =
          Metadata.with_category(level, :client,
            conn_id: entry.conn_id,
            device_id: entry.device_id,
            # web vs plugin: both ship through this pipe, and a web-only alert
            # (broken SPA API requests) has to tell them apart.
            platform: entry.platform,
            user_id: hashed_user,
            client_severity: entry.level,
            # The whole point of `forced` is answering "does this signal cover
            # the WHOLE fleet, or only opted-in users?" — and this re-emit is
            # where that question gets asked, because it is the surface that is
            # greppable in one Loki query WITHOUT the read-only DB bastion.
            # Persisting it to client_logs alone would have left the on-call
            # path exactly as blind as before.
            forced: entry.forced
          )
          |> Keyword.merge(entry.context)

        meta = if repeat > 1, do: Keyword.put(meta, :repeat, repeat), else: meta

        # Verbose diagnostic-mode entries opt into Loki per-entry even at :info,
        # up to @max_diagnostic_ships per batch. Via Metadata.ship_to_loki/1,
        # never a bare Keyword.put: the routing field Fluent Bit reads is the
        # STRING, and setting the boolean alone made this override a silent
        # no-op (engram-app/engram-infra#1095).
        meta = if ship?, do: Metadata.ship_to_loki(meta), else: meta

        Logger.log(level, msg, meta)
      rescue
        e ->
          Logger.warning(
            "client log re-emit failed: #{Metadata.safe_reason(e)}",
            Engram.Logger.Metadata.with_category(:warning, :client, [])
          )
      end
    end)
  end

  # Identical lines of one batch (a refused frame retried per flush) as one
  # `{first, count}`, in first-seen order. Everything that ends up in the line
  # or its metadata is part of the key, so collapsing never merges two lines
  # that would have read differently, except `elapsed_ms`: it differs on every
  # network_error, so keying on it never collapsed a burst. A collapsed line
  # carries the range instead (`elapsed_ms` = slowest, `elapsed_ms_min` =
  # fastest), which still tells a run of fast failures from one stall.
  defp collapse_repeats(items) do
    {order, groups} =
      Enum.reduce(items, {[], %{}}, fn {e, ship?} = item, {order, groups} ->
        key =
          {e.level, e.category, e.message, ship?, e.forced, e.conn_id, e.device_id, e.platform,
           Keyword.delete(e.context, :elapsed_ms)}

        case groups do
          %{^key => {first, elapsed}} ->
            {order, Map.put(groups, key, {first, [e.context[:elapsed_ms] | elapsed]})}

          _ ->
            {[key | order], Map.put(groups, key, {item, [e.context[:elapsed_ms]]})}
        end
      end)

    order
    |> Enum.reverse()
    |> Enum.map(fn key ->
      {{first, ship?}, elapsed} = Map.fetch!(groups, key)
      {{%{first | context: elapsed_range(first.context, elapsed)}, ship?}, length(elapsed)}
    end)
  end

  defp elapsed_range(context, [_one]), do: context

  defp elapsed_range(context, elapsed) do
    case Enum.reject(elapsed, &is_nil/1) do
      [] ->
        context

      timed ->
        context
        |> Keyword.put(:elapsed_ms, Enum.max(timed))
        |> Keyword.put(:elapsed_ms_min, Enum.min(timed))
    end
  end

  # How many diagnostic entries this batch may ship, and how many it loses.
  defp diagnostic_budget(entries) do
    wanted = Enum.count(entries, & &1.diagnostic)
    {min(wanted, @max_diagnostic_ships), max(wanted - @max_diagnostic_ships, 0)}
  end

  # Client severity is capped at :warning on re-emit — never :error — so a
  # broken plugin loop cannot masquerade as a backend error.
  defp normalize_level("warn"), do: :warning
  defp normalize_level("error"), do: :warning
  defp normalize_level(_), do: :info
end
