defmodule Engram.HistorySessionGapConfigTest do
  # HISTORY_SESSION_GAP_MINUTES below 1 would close a version on every save
  # (0) or never match the gap check sensibly (negative). Refuse it at boot.
  use ExUnit.Case, async: false

  @var "HISTORY_SESSION_GAP_MINUTES"

  setup do
    previous = System.get_env(@var)

    on_exit(fn ->
      if previous, do: System.put_env(@var, previous), else: System.delete_env(@var)
    end)
  end

  defp read_runtime, do: Config.Reader.read!("config/runtime.exs", env: :test, target: :host)

  test "a positive value is used" do
    System.put_env(@var, "5")
    assert get_in(read_runtime(), [:engram, :history_session_gap_minutes]) == 5
  end

  for bad <- ["0", "-3"] do
    test "#{bad} refuses to boot" do
      System.put_env(@var, unquote(bad))

      assert_raise RuntimeError,
                   ~r/HISTORY_SESSION_GAP_MINUTES must be at least 1/,
                   &read_runtime/0
    end
  end
end
