defmodule Engram.Auth.SignupRejections do
  @moduledoc """
  Short-lived record of sign-ups rejected server-side, keyed by Clerk user id.

  The `user.created` webhook deletes the Clerk user when a sign-up trips the
  multi-account block (see `Engram.Auth.Clerk.Webhook`). That delete orphans the
  freshly-created session, so the web app bounces to sign-in with no idea why.
  We stash the reason here *before* the delete, and the app fetches it via a
  public endpoint to show an accurate "account already exists" message.

  ETS-backed, single-node — same shape as `EngramWeb.RateLimiter`. Records are
  ephemeral by nature (a few seconds of life is enough); a periodic sweep drops
  anything past its TTL so the table can't grow unbounded.
  """

  use GenServer

  @table __MODULE__
  # Only read once, on the sign-in bounce moments after the delete. A short TTL
  # keeps the (low-risk, opaque-id) lookup oracle from lingering. The frontend's
  # own freshness window is 2 min; 5 gives comfortable slack without persisting.
  @default_ttl_ms :timer.minutes(5)
  @sweep_interval_ms :timer.minutes(10)

  @type reason :: :duplicate_identity

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Record a rejection reason for a Clerk user id. TTL is in milliseconds."
  @spec record(String.t(), reason(), non_neg_integer() | integer()) :: :ok
  def record(clerk_user_id, reason, ttl_ms \\ @default_ttl_ms)
      when is_binary(clerk_user_id) and is_atom(reason) do
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(@table, {clerk_user_id, reason, expires_at})
    :ok
  end

  @doc "Fetch a live (unexpired) rejection reason for a Clerk user id."
  @spec fetch(String.t()) :: {:ok, reason()} | :error
  def fetch(clerk_user_id) when is_binary(clerk_user_id) do
    case :ets.lookup(@table, clerk_user_id) do
      [{^clerk_user_id, reason, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, reason}
        else
          :ets.delete(@table, clerk_user_id)
          :error
        end

      [] ->
        :error
    end
  end

  @impl true
  def init(_opts) do
    _table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
