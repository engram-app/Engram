defmodule Mix.Tasks.Engram.Lint.NoClientOnlyRateLimitsTest do
  use ExUnit.Case, async: true

  alias Engram.Billing.LimitKeys
  alias Mix.Tasks.Engram.Lint.NoClientOnlyRateLimits, as: Lint

  describe "self-scan" do
    test "every catalog key is either enforced server-side or in @opt_outs" do
      # The @opt_outs map captures every key that is intentionally not enforced
      # server-side. Any new restrictive Free default added to LimitKeys without
      # a corresponding enforcement site or opt-out entry will fail this test.
      opt_out_keys = MapSet.new(Map.keys(Lint.__opt_outs__()))

      lib_files =
        Path.wildcard("lib/**/*.ex")
        |> Enum.reject(&String.contains?(&1, "lib/mix/tasks/"))

      blob = Enum.map_join(lib_files, "\n", &File.read!/1)

      missing =
        Enum.reject(LimitKeys.all(), fn k ->
          unrestricted?(LimitKeys.default_for(k, :free)) or
            MapSet.member?(opt_out_keys, k) or
            String.contains?(blob, ":#{k}")
        end)

      assert missing == [],
             """
             The following Free-restrictive limit keys are NOT enforced server-side
             and NOT listed in @opt_outs of NoClientOnlyRateLimits:

             #{Enum.map_join(missing, "\n  ", &":#{&1}")}

             Either add a Billing.{check_limit, effective_limit} call site in lib/,
             or add the key to @opt_outs with a reason.
             """
    end
  end

  defp unrestricted?(nil), do: true
  defp unrestricted?(true), do: true
  defp unrestricted?(_), do: false
end
