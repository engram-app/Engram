defmodule Engram.StalledDekLoad do
  @moduledoc """
  Puts a user's DEK load in the state a stalled KMS call leaves it: the cached
  DEK evicted and another process holding the reload claim, so the next
  `Crypto.get_dek/1` from the calling test (or a `$callers` child) waits out a
  20 ms `:dek_await_ms` and returns
  `{:error, :dek_load_timeout}`. Call from the test process (it registers
  `on_exit` cleanup). Returns the claim token, so a test can fill the slot
  later with `DekCache.put_if_claimed/3`.
  """
  # Whole module: assert_receive expands to flunk/1.
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Engram.Crypto.DekCache

  @spec stall!(term()) :: term()
  def stall!(user_id) do
    # Per process (and its $callers), so async tests never see each other's.
    :ok = Engram.ServiceConfig.put_override(:dek_await_ms, 20)
    :ok = DekCache.invalidate(user_id)
    caller = self()

    holder =
      spawn(fn ->
        send(caller, {:stalled_dek_claim, DekCache.claim(user_id)})
        Process.sleep(:infinity)
      end)

    on_exit(fn -> Process.exit(holder, :kill) end)
    assert_receive {:stalled_dek_claim, token}
    token
  end
end
