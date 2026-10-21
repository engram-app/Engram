defmodule Engram.Analytics.EventLog do
  @moduledoc """
  Our own copy of every `Engram.Analytics` event (`analytics_events`), so the
  operator insights can answer funnel questions without PostHog.

  `Engram.Analytics` decides WHETHER an event is recorded (opt-out,
  throttling); this only writes it. After the caller's transaction commits
  the row goes into an in-memory buffer (`EventLog.Buffer`), which writes
  every buffered row in one statement per flush: every few seconds, as soon
  as it holds 500 rows, and on shutdown. So the insert is never part of
  the caller's transaction, a failure never reaches the caller, and a burst
  of events costs one statement, not one task and insert each. A hard crash
  loses at most one interval of rows (accepted: this is analytics, not an
  audit log).

  On by default (`config :engram, :analytics_event_log`); off in test, where
  a test turns it on.
  """

  alias Engram.Logger.Metadata
  alias Engram.Repo

  require Logger

  # The only prop keys stored, each holding a bounded value: an enum, a
  # bucket, a count, an id or a version. An allowlist, not a denylist, so a
  # prop added later (free text a user typed, a reply address, a user agent)
  # is dropped until someone decides it is safe and lists it here. PostHog
  # gets the full props under the feedback policy; `$`-prefixed person
  # updates are never facts about the event.
  @allowed ~w(
    action amount_bucket app_locale app_version area attachments auth_method cadence calls
    category choice client client_agent client_type contact_ok cross_vault
    currency device discounted duration_ms error errors events failed folders
    from_tier grant_id grant_type heard_from initiated_by interval item
    jwks_source kind languages latency_ms limit_key method missing mood next_step
    note_count notes notes_bucket origin outcome paddle_subscription_id phase
    plan platform plugin_version price_id reason referrer_domain registration
    result result_count scopes_granted scopes_requested server_version
    signup_source signup_tool silent skipped source status step surface
    surfaces_used tenure_bucket tier to to_tier tool tool_name tools total trigger
    use_cases utm_campaign utm_content utm_medium utm_source vault_id
    vault_number vaults_left via within_grace
  )
  # Every allowed value is short; a longer one is cut, never stored whole.
  @max_string 64
  @max_list 32

  @doc "The prop keys `record/3` keeps."
  @spec allowed_keys() :: [String.t()]
  def allowed_keys, do: @allowed

  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:engram, :analytics_event_log, true)

  @table __MODULE__.Buffer
  @flush_at 500
  @chunk 1_000

  @doc "Record `event` for `user_id` (nil: anonymous). Fire-and-forget."
  @spec record(Ecto.UUID.t() | nil, String.t(), map()) :: :ok
  def record(user_id, event, props) do
    if enabled?() do
      row = {user_id, event, props |> bounded() |> coarse(event), at(event)}
      Repo.after_commit(fn -> buffer(row) end)
    end

    :ok
  end

  # A deleted account's anonymous summary must not be joinable back to the
  # deletion: stored at day precision, its plan only free or paid. PostHog
  # keeps its own copy as sent.
  @day_precision ~w(account_deleted account_delete_reason)

  defp at(event) when event in @day_precision,
    do: DateTime.new!(Date.utc_today(), ~T[00:00:00.000000], "Etc/UTC")

  defp at(_event), do: DateTime.utc_now()

  defp coarse(%{"plan" => plan} = props, "account_deleted"),
    do: Map.put(props, "plan", if(plan == "free", do: "free", else: "paid"))

  defp coarse(props, _event), do: props

  defp buffer({user_id, _, _, _} = row) do
    true = :ets.insert(@table, {:erlang.unique_integer([:monotonic]), user_id, row})

    if :ets.info(@table, :size) >= @flush_at,
      do: send(__MODULE__.Buffer, :flush)

    :ok
  rescue
    # Table absent (buffer not started, or restarting): the row is dropped
    # rather than failing the caller.
    ArgumentError -> :ok
  end

  @doc """
  Write every buffered row and empty the buffer. Runs in the caller's
  process: the buffer's timer, its shutdown, and tests (which have no timer).
  """
  @spec flush() :: :ok
  def flush do
    if :ets.whereis(@table) == :undefined do
      :ok
    else
      keys = :ets.select(@table, [{{:"$1", :_, :_}, [], [:"$1"]}])
      # take/2 per key: atomic read-and-delete, so a row buffered during the
      # flush lands in this flush or the next, never in both.
      rows = for key <- Enum.sort(keys), [{_, _, row}] <- [:ets.take(@table, key)], do: row
      rows |> Enum.chunk_every(@chunk) |> Enum.each(&insert/1)
    end
  end

  @doc "Drop `user_id`'s rows still waiting in the buffer (an opt-out)."
  @spec discard(Ecto.UUID.t()) :: :ok
  def discard(user_id) do
    if :ets.whereis(@table) != :undefined, do: :ets.match_delete(@table, {:_, user_id, :_})
    :ok
  end

  @doc false
  def table, do: @table

  defp bounded(props) do
    for {k, v} <- props,
        k = to_string(k),
        k in @allowed,
        v = value(v),
        v != :drop,
        into: %{},
        do: {k, v}
  end

  defp value(v) when is_binary(v), do: String.slice(v, 0, @max_string)
  defp value(v) when is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp value(v) when is_atom(v), do: v |> Atom.to_string() |> value()

  defp value(v) when is_list(v) do
    if Enum.all?(v, &(is_binary(&1) or is_atom(&1))),
      do: v |> Enum.take(@max_list) |> Enum.map(&value/1),
      else: :drop
  end

  defp value(_v), do: :drop

  # One statement per chunk. A row whose user was deleted after the event is
  # skipped by the users check instead of failing the whole chunk on the FK.
  @insert """
  INSERT INTO analytics_events (user_id, event, props, inserted_at)
  SELECT v.user_id, v.event, v.props, v.inserted_at
  FROM unnest($1::uuid[], $2::text[], $3::jsonb[], $4::timestamptz[])
    AS v(user_id, event, props, inserted_at)
  WHERE v.user_id IS NULL OR EXISTS (SELECT 1 FROM users u WHERE u.id = v.user_id)
  """

  defp insert(rows) do
    params = [
      Enum.map(rows, fn {id, _, _, _} -> id && Ecto.UUID.dump!(id) end),
      Enum.map(rows, &elem(&1, 1)),
      Enum.map(rows, &elem(&1, 2)),
      Enum.map(rows, &elem(&1, 3))
    ]

    _ = Repo.query!(@insert, params)
    :ok
  rescue
    # Analytics must never take the buffer down; the chunk is lost, said once.
    e -> dropped(rows, inspect(e.__struct__))
  catch
    :exit, _reason -> dropped(rows, "exit")
  end

  defp dropped(rows, why) do
    Logger.warning(
      "analytics events not stored: #{length(rows)} rows, #{why}",
      Metadata.with_category(:warning, :lifecycle, [])
    )
  end
end
