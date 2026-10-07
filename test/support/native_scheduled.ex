defmodule Engram.NativeScheduled do
  @moduledoc false
  import ExUnit.Assertions

  # `call.(n)` must reach NIF `nif` with exactly `n` input bytes, as
  # `Engram.Native` counts them. Asserts the `sized/3` boundary: 16 KB runs
  # on the calling scheduler, one byte more on a dirty one.
  def assert_scheduled(nif, call) do
    ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :nif, :call, :stop]])

    for {n, dirty} <- [{16_384, false}, {16_385, true}] do
      call.(n)
      assert_receive {_, ^ref, %{input_bytes: ^n}, %{nif: ^nif, dirty: ^dirty}}
    end

    :telemetry.detach(ref)
  end
end
