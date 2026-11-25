defmodule Engram.ServiceConfig.Flags do
  @moduledoc """
  The reviewed flags file: an allowlist of operational settings
  (`Engram.ServiceConfig.Overrides.flag_keys/0`) changed only by a PR to
  engram-infra `main/envs/<env>/service_flags.json`. Prod reads it from AWS
  AppConfig, staging from a file (`SERVICE_FLAGS_FILE`); self-host sets
  neither, starts no reader and keeps the DB override path for every key.
  Runbook: `docs/context/service-flags.md`.

  ## Reads

  The current map lives in `:persistent_term` (one lookup, no copy, no
  query). `Overrides.fetch/1` reads a flag key from it alone (a DB row for
  the key is ignored), then env. A flag change is visible on this node the moment its poll installs it,
  so there is no cache to evict; each node polls on its own (60 s).

  ## Fail-safe

  An unreachable source or a bad document keeps the last good map, with one
  warning per state change (not per poll). A reader that has never loaded
  serves an empty map, so flag keys read env. Every successful load (the
  first and each change) logs one `service_flags_loaded` line, `:lifecycle`
  info, which ships to Loki: the first prod check after a release. Per key: an unknown key is
  dropped and a value that fails `Overrides.validate/2` keeps that key's old
  value, each with one error line; the other keys still apply. Duplicate
  JSON keys reject the whole document (a reviewer reads the first, a parser
  keeps the last).

  ## paused_accounts

  Flags-only (`%{id => until}`): `paused?/1` judges `until` against the clock
  on every read, so an expired entry is ignored with no redeploy. An entry
  more than `ClientLocks.max_expiry_s/0` (30 days) ahead is ignored, as is a
  `plugin_floor` expiring past it. `Engram.ClientGate.paused/1` ORs it with
  the billing-override quarantine. A newly paused or lifted id has its
  sockets dropped (`SessionInvalidator`), and a `plugin_floor` change asks
  `user:` channels to recheck (`Engram.Admin.ClientLocks.recheck/1`), as the
  rpc does. A first load (boot, or after a reader restart) does both for
  EVERY paused id and floor: sockets may have joined before it. A body over
  256 KB is an invalid document.

  Never touches the database.
  """

  use GenServer

  alias Engram.Admin.ClientLocks
  alias Engram.Auth.SessionInvalidator
  alias Engram.Crypto.HMAC
  alias Engram.Logger.Metadata
  alias Engram.PluginVersion
  alias Engram.ServiceConfig.Flags.FileSource
  alias Engram.ServiceConfig.Overrides

  require Logger

  @flags_key {__MODULE__, :flags}
  @paused_key {__MODULE__, :paused}
  @poll_ms 60_000
  @max_paused 1000
  @max_body FileSource.max_bytes()
  # Hashed ids named in one change line; the counts carry the rest.
  @max_listed 20
  @uuid ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  # -- reads (any process) ----------------------------------------------------

  @doc "Whether a flags source is configured (prod AppConfig, staging file)."
  @spec configured?() :: boolean()
  def configured?, do: Application.get_env(:engram, :service_flags) != nil

  @doc "The flags in force on this node."
  @spec current() :: %{optional(atom()) => term()}
  def current, do: :persistent_term.get(@flags_key, %{})

  @spec fetch(atom()) :: {:ok, term()} | :error
  def fetch(key), do: Map.fetch(current(), key)

  @doc "Whether `user_id` has an unexpired `paused_accounts` entry."
  @spec paused?(term()) :: boolean()
  def paused?(user_id) when is_binary(user_id) do
    case :persistent_term.get(@paused_key, %{}) do
      none when map_size(none) == 0 -> false
      paused -> active?(Map.get(paused, String.downcase(user_id)), DateTime.utc_now())
    end
  end

  def paused?(_), do: false

  @doc """
  Parses a `paused_accounts` value into `%{lowercase id => until}`: at most
  #{@max_paused} entries of exactly `id` (a uuid, unique) and `until` (ISO
  8601 UTC ending `Z`). A past `until` is valid (read as not paused).
  """
  @spec parse_paused(term()) :: {:ok, %{String.t() => DateTime.t()}} | :error
  def parse_paused(list) when is_list(list) and length(list) <= @max_paused do
    Enum.reduce_while(list, {:ok, %{}}, fn entry, {:ok, acc} ->
      case paused_entry(entry) do
        {:ok, id, until} when not is_map_key(acc, id) -> {:cont, {:ok, Map.put(acc, id, until)}}
        _ -> {:halt, :error}
      end
    end)
  end

  def parse_paused(_), do: :error

  defp paused_entry(%{"id" => id, "until" => until} = entry)
       when map_size(entry) == 2 and is_binary(id) and is_binary(until) do
    with true <- Regex.match?(@uuid, id),
         true <- String.ends_with?(until, "Z"),
         {:ok, at, 0} <- DateTime.from_iso8601(until) do
      {:ok, String.downcase(id), at}
    else
      _ -> :error
    end
  end

  defp paused_entry(_), do: :error

  defp active?(nil, _now), do: false
  defp active?(until, now), do: DateTime.compare(until, now) == :gt

  # -- the reader -------------------------------------------------------------

  @spec start_link({:file, String.t()} | {:appconfig, map()}) :: GenServer.on_start()
  def start_link(source), do: GenServer.start_link(__MODULE__, source, name: __MODULE__)

  @impl true
  def init(source) do
    state = %{
      source: source,
      token: nil,
      last_body: nil,
      doc_status: :ok,
      status: :ok,
      loaded?: false,
      ignored_logged: MapSet.new()
    }

    {:ok, state, {:continue, :poll}}
  end

  @impl true
  def handle_continue(:poll, state), do: {:noreply, poll(state)}

  @impl true
  def handle_info(:poll, state), do: {:noreply, poll(state)}

  defp poll(state) do
    Process.send_after(self(), :poll, @poll_ms)

    case read(state) do
      {:ok, body, version, state} -> state |> load(body, version) |> status(nil)
      {:error, reason, state} -> state |> status(:unreachable, reason)
    end
    |> log_ignored()
  end

  # An empty AppConfig body, or the same file bytes: nothing changed, and a
  # document already found bad is not re-reported.
  defp load(state, body, _version) when body == "" or body == state.last_body, do: state

  # A reviewed file is a few KB; anything this big is not one.
  defp load(state, body, _version) when byte_size(body) > @max_body,
    do: %{state | last_body: body, doc_status: :invalid}

  defp load(state, body, version) do
    state = %{state | last_body: body}

    case decode(body) do
      {:ok, doc} when is_map(doc) ->
        first? = not state.loaded?
        state = install(state, build(doc, current()))

        Logger.info(
          "service_flags_loaded source=#{kind(state)} keys=#{map_size(current())} " <>
            "version=#{version} first=#{first?}",
          Metadata.with_category(:info, :lifecycle)
        )

        %{state | doc_status: :ok}

      _ ->
        %{state | doc_status: :invalid}
    end
  end

  defp status(state, reason), do: status(state, state.doc_status, reason)

  # One warning per state change, never per poll.
  defp status(%{status: now} = state, now, _reason), do: state

  defp status(state, now, reason) do
    message =
      case now do
        :ok -> "service flags source healthy again"
        :unreachable -> "service flags source unreachable; keeping the last good flags"
        :invalid -> "service flags document invalid; keeping the last good flags"
      end

    Logger.warning(
      "#{message} source=#{kind(state)}",
      Metadata.with_category(:warning, :data, reason: reason)
    )

    %{state | status: now}
  end

  # Every key of `doc` that is a flag key with a valid value. A bad value
  # keeps the key's old value; an unknown key is dropped.
  defp build(doc, old) do
    Enum.reduce(doc, %{}, fn {name, value}, acc ->
      case Overrides.flag_key(name) do
        {:ok, key} ->
          case {Overrides.validate(key, value), within_cap?(key, value)} do
            {:ok, true} ->
              Map.put(acc, key, value)

            _ ->
              rejected(name, "invalid value, keeping the old one")
              if Map.has_key?(old, key), do: Map.put(acc, key, old[key]), else: acc
          end

        :error ->
          rejected(name, "unknown key")
          acc
      end
    end)
  end

  # `plugin_floor.expires_at` at most ClientLocks' 30 days ahead, as the rpc
  # lock requires (`parse_lock/1` allows any date).
  defp within_cap?(:plugin_floor, %{"expires_at" => exp}) do
    case DateTime.from_iso8601(exp) do
      {:ok, at, _} -> DateTime.diff(at, DateTime.utc_now()) <= ClientLocks.max_expiry_s()
      _ -> false
    end
  end

  defp within_cap?(_key, _value), do: true

  defp rejected(name, why) do
    Logger.error(
      "service flag rejected key=#{inspect(String.slice(to_string(name), 0, 64))} (#{why})",
      Metadata.with_category(:error, :data)
    )
  end

  # The only :persistent_term writes, and only on a change: each is a global GC.
  defp install(state, flags) do
    old = current()

    if flags != old do
      :ok = log_changes(old, flags, kind(state))
      :persistent_term.put(@flags_key, flags)
    end

    paused = paused_map(flags)

    if paused != :persistent_term.get(@paused_key, %{}),
      do: :persistent_term.put(@paused_key, paused),
      else: :ok

    :ok = enforce(state.loaded?, old, flags)
    %{state | loaded?: true}
  end

  # Sockets: after a change, the ids that were paused or lifted are dropped
  # and the floor is rechecked. A first load (boot, or the first after a
  # reader restart) may face sockets that joined before any flag was read,
  # so it drops EVERY paused id and rechecks every floor; with no matching
  # socket that costs one broadcast each.
  defp enforce(true, same, same), do: :ok

  defp enforce(loaded?, old, new) do
    now = DateTime.utc_now()
    before = active_ids(old, now)
    after_ = active_ids(new, now)

    changed =
      if loaded?,
        do: MapSet.symmetric_difference(before, after_),
        else: MapSet.union(before, after_)

    Enum.each(changed, &SessionInvalidator.disconnect_user/1)

    recheck_floor(loaded?, old, new)
  end

  # As `ClientLocks` does on a lock or a lift: sockets below the old or the
  # new min rejoin against the floor now in force.
  defp recheck_floor(loaded?, old, new) do
    if not loaded? or old[:plugin_floor] != new[:plugin_floor] or
         old[:plugin_floor_enabled] != new[:plugin_floor_enabled] do
      [old[:plugin_floor], new[:plugin_floor]]
      |> Enum.uniq()
      |> Enum.each(fn lock ->
        with {:ok, %{min: min}} <- PluginVersion.parse_lock(lock),
             do: ClientLocks.recheck(Version.to_string(min))
      end)
    end

    :ok
  end

  # What the file says (validated), whatever the clock.
  defp raw_paused(flags) do
    case parse_paused(Map.get(flags, :paused_accounts, [])) do
      {:ok, paused} -> paused
      :error -> %{}
    end
  end

  # What pauses: entries `until` at most 30 days ahead (the ClientLocks cap).
  defp paused_map(flags) do
    now = DateTime.utc_now()
    raw_paused(flags) |> Map.reject(fn {_id, until} -> beyond_cap?(until, now) end)
  end

  defp beyond_cap?(until, now), do: DateTime.diff(until, now) > ClientLocks.max_expiry_s()

  defp active_ids(flags, now) do
    for {id, until} <- paused_map(flags), active?(until, now), into: MapSet.new(), do: id
  end

  defp log_changes(old, new, source) do
    (Map.keys(old) ++ Map.keys(new))
    |> Enum.uniq()
    |> Enum.reject(&(old[&1] == new[&1]))
    |> Enum.each(fn key ->
      Logger.warning(
        "service flag changed key=#{key} #{shown(key, old, new)} source=#{source}",
        Metadata.with_category(:warning, :data)
      )
    end)
  end

  # paused_accounts: counts and hashed ids, never a raw id.
  defp shown(:paused_accounts, old, new) do
    before = raw_paused(old)
    after_ = raw_paused(new)
    added = Map.keys(after_) -- Map.keys(before)
    removed = Map.keys(before) -- Map.keys(after_)

    "old=#{map_size(before)} new=#{map_size(after_)} added=#{hashes(added)} removed=#{hashes(removed)}"
  end

  defp shown(key, old, new), do: "old=#{value(old, key)} new=#{value(new, key)}"

  defp value(flags, key),
    do: if(Map.has_key?(flags, key), do: inspect(flags[key]), else: "(unset)")

  defp hashes(ids) do
    listed = ids |> Enum.take(@max_listed) |> Enum.map_join(",", &HMAC.hash_user_id/1)
    more = length(ids) - @max_listed
    "[#{listed}]" <> if(more > 0, do: "+#{more}", else: "")
  end

  # One line per entry the first time this node sees it ignored: expired, or
  # `until` beyond the 30-day cap.
  defp log_ignored(state) do
    now = DateTime.utc_now()

    ignored =
      for {id, until} <- raw_paused(current()),
          why = ignored_why(until, now),
          why != nil,
          into: MapSet.new(),
          do: {id, why}

    for {id, why} <- MapSet.difference(ignored, state.ignored_logged) do
      Logger.warning(
        "service flag paused_accounts entry #{why}, ignored user=#{HMAC.hash_user_id(id)}",
        Metadata.with_category(:warning, :data)
      )
    end

    %{state | ignored_logged: ignored}
  end

  defp ignored_why(until, now) do
    cond do
      not active?(until, now) -> "expired"
      beyond_cap?(until, now) -> "beyond the 30-day cap"
      true -> nil
    end
  end

  defp kind(%{source: {kind, _}}), do: kind

  # -- sources ----------------------------------------------------------------

  # The file's version is its mtime (unix seconds).
  defp read(%{source: {:file, path}} = state) do
    case FileSource.read(path) do
      {:ok, body, mtime} -> {:ok, body, mtime, state}
      {:error, reason} -> {:error, inspect(reason), state}
    end
  end

  # Any failure drops the session: the next poll starts a new one, whose
  # first GetLatestConfiguration returns the whole document again (the
  # `last_body` check makes that a no-op). Covers the 24 h token expiry.
  defp read(%{source: {:appconfig, cfg}} = state) do
    with {:ok, token} <- session(state.token, cfg),
         {:ok, body, next, version} <- latest(token, cfg) do
      {:ok, body, version, %{state | token: next}}
    else
      {:error, reason} -> {:error, reason, %{state | token: nil}}
    end
  end

  defp session(token, _cfg) when is_binary(token), do: {:ok, token}

  defp session(nil, cfg) do
    body = %{
      "ApplicationIdentifier" => cfg.application,
      "EnvironmentIdentifier" => cfg.environment,
      "ConfigurationProfileIdentifier" => cfg.profile,
      "RequiredMinimumPollIntervalInSeconds" => div(@poll_ms, 1000)
    }

    with {:ok, resp} <- http(cfg, method: :post, url: "/configurationsessions", json: body),
         {:ok, %{"InitialConfigurationToken" => token}} when is_binary(token) <-
           Jason.decode(resp.body) do
      {:ok, token}
    else
      {:error, _} = e -> e
      _ -> {:error, "bad session response"}
    end
  end

  defp latest(token, cfg) do
    with {:ok, resp} <-
           http(cfg, method: :get, url: "/configuration", params: [configuration_token: token]) do
      case Req.Response.get_header(resp, "next-poll-configuration-token") do
        [next | _] -> {:ok, resp.body, next, version_label(resp)}
        [] -> {:error, "no next poll token"}
      end
    end
  end

  # AppConfig's `Version-Label` (set on the hosted version), else unlabelled.
  defp version_label(resp) do
    case Req.Response.get_header(resp, "version-label") do
      [label | _] -> String.slice(label, 0, 64)
      [] -> "unlabelled"
    end
  end

  defp http(cfg, opts) do
    [
      base_url: "https://appconfigdata.#{cfg.region}.amazonaws.com",
      aws_sigv4: {__MODULE__, :aws_credentials, [cfg.region]},
      # The raw bytes: decoding here would hide duplicate keys.
      decode_body: false,
      retry: false,
      receive_timeout: 10_000
    ]
    |> Keyword.merge(Application.get_env(:engram, :service_flags_req_options, []))
    |> Keyword.merge(opts)
    |> Req.request()
    |> case do
      {:ok, %{status: status} = resp} when status in 200..299 -> {:ok, resp}
      {:ok, %{status: status}} -> {:error, "http #{status}"}
      {:error, e} -> {:error, Metadata.safe_reason(e)}
    end
  rescue
    e -> {:error, Metadata.safe_reason(e)}
  end

  @doc false
  # The task role through ex_aws's credential chain (the one S3 and KMS use).
  # ex_aws has no AppConfig Data service, so Req signs; signing name `appconfig`.
  def aws_credentials(region) do
    aws = ExAws.Config.new(:s3, region: region)

    [
      access_key_id: aws.access_key_id,
      secret_access_key: aws.secret_access_key,
      token: aws[:security_token],
      service: :appconfig,
      region: region
    ]
  end

  # Duplicate keys at any depth reject the document.
  defp decode(body) do
    with {:ok, doc} <- Jason.decode(body, objects: :ordered_objects), do: plain(doc)
  end

  defp plain(%Jason.OrderedObject{values: pairs}) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      case plain(v) do
        {:ok, _} when is_map_key(acc, k) -> {:halt, {:error, :duplicate_key}}
        {:ok, v} -> {:cont, {:ok, Map.put(acc, k, v)}}
        err -> {:halt, err}
      end
    end)
  end

  defp plain(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn v, {:ok, acc} ->
      case plain(v) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, l} -> {:ok, Enum.reverse(l)}
      err -> err
    end
  end

  defp plain(v), do: {:ok, v}
end
