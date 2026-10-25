defmodule Engram.NativeScheduled do
  @moduledoc false
  import ExUnit.Assertions

  @event [:engram, :nif, :call, :stop]

  @doc """
  Attaches a `#{inspect(@event)}` handler that forwards, as
  `{event, ref, measurements, metadata}`, only the events the calling test
  process emits. `:telemetry_test.attach_event_handlers/2` is global: in an
  async suite any other test's NIF call lands in this mailbox too, so a
  count or a `refute_receive` flakes. Handlers run in the emitting process,
  so `self()` there is the caller. Detached on test exit.
  """
  def attach_nif_events do
    ref = make_ref()
    :telemetry.attach(ref, @event, &__MODULE__.forward/4, {self(), ref})
    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(ref) end)
    ref
  end

  @doc false
  def forward(event, measurements, metadata, {pid, ref}) do
    if self() == pid, do: send(pid, {event, ref, measurements, metadata})
  end

  # `call.(n)` must reach NIF `nif` with exactly `n` input bytes, as
  # `Engram.Native` counts them. Asserts the `sized/3` boundary: 16 KB runs
  # on the calling scheduler, one byte more on a dirty one.
  def assert_scheduled(nif, call) do
    ref = attach_nif_events()

    for {n, dirty} <- [{16_384, false}, {16_385, true}] do
      call.(n)
      assert_receive {_, ^ref, %{input_bytes: ^n}, %{nif: ^nif, dirty: ^dirty}}
    end

    :telemetry.detach(ref)
  end
end
