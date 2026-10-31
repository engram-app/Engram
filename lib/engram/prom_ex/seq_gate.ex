defmodule Engram.PromEx.SeqGate do
  @moduledoc """
  PromEx plugin for `Engram.Vaults.SeqGate`, the per-vault write queue. Without
  it, saturation is invisible until clients see 429s.

    * `..._seq_gate_acquire_total{result}`: gate decisions, `ok | busy`.
      `busy` is a shed write (429).
    * `..._seq_gate_wait_milliseconds`: time queued before the gate.
    * `..._seq_gate_hold_milliseconds`: time holding it (the write transaction).
    * `..._seq_gate_held` / `..._seq_gate_waiting`: per-node gauges, polled.
    * `..._seq_gate_db_shed_total{code, class}`: requests their own DB bound
      cancelled (`Engram.Repo.ShedError`); `code` is the SQLSTATE name, `class`
      the route class. Same family as the gate: load shed at the DB.

  Cardinality: `result`, `code` (2) and `class` (3) only. Never the vault id.
  """

  use PromEx.Plugin

  alias Engram.PromEx.Buckets

  defmodule MsBuckets do
    @moduledoc false
    # Edges around the 10s wait budget (`:seq_gate_wait_ms`) so a shed write
    # (waited the full budget plus overhead) lands in 12.5s, not +Inf.
    use Engram.PromEx.Buckets, [1, 5, 25, 100, 500, 2_500, 7_500, 10_000, 12_500, 20_000]
  end

  @impl true
  def event_metrics(opts) do
    prefix = PromEx.metric_prefix(Keyword.fetch!(opts, :otp_app), :seq_gate)

    Event.build(:engram_seq_gate_event_metrics, [
      counter(prefix ++ [:acquire, :total],
        event_name: [:engram, :seq_gate, :acquire],
        description: "Vault write-gate decisions: ok, or busy (shed with a 429).",
        tags: [:result]
      ),
      distribution(prefix ++ [:wait, :milliseconds],
        event_name: [:engram, :seq_gate, :acquire],
        measurement: :duration,
        unit: {:native, :millisecond},
        description: "Time a write waited for its vault's gate.",
        tags: [:result],
        reporter_options: Buckets.opts(MsBuckets)
      ),
      counter(prefix ++ [:db_shed, :total],
        event_name: [:engram, :repo, :shed],
        description:
          "Requests their own DB bound cancelled (Engram.Repo.ShedError): " <>
            "lock_not_available (429) or query_canceled (503), by route class.",
        tags: [:code, :class]
      ),
      distribution(prefix ++ [:hold, :milliseconds],
        event_name: [:engram, :seq_gate, :hold],
        measurement: :duration,
        unit: {:native, :millisecond},
        description: "Time a write held its vault's gate.",
        reporter_options: Buckets.opts(MsBuckets)
      )
    ])
  end

  @impl true
  def polling_metrics(opts) do
    prefix = PromEx.metric_prefix(Keyword.fetch!(opts, :otp_app), :seq_gate)

    Polling.build(
      :engram_seq_gate_polling_metrics,
      Keyword.get(opts, :seq_gate_poll_rate, 5_000),
      {__MODULE__, :execute_queue_metrics, []},
      [
        last_value(prefix ++ [:held],
          event_name: [:engram, :seq_gate, :queue],
          measurement: :held,
          description: "Vaults whose write gate is held on this node."
        ),
        last_value(prefix ++ [:waiting],
          event_name: [:engram, :seq_gate, :queue],
          measurement: :waiting,
          description: "Writes queued on a vault write gate on this node."
        )
      ]
    )
  end

  @doc "Polled emitter for the per-node queue gauges."
  def execute_queue_metrics do
    depth =
      try do
        Engram.Vaults.SeqGate.queue_depth()
      catch
        :exit, _ -> %{held: 0, waiting: 0}
      end

    :telemetry.execute([:engram, :seq_gate, :queue], depth, %{})
  end
end
