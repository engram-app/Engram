defmodule Engram.PromEx.OAuthTest do
  @moduledoc """
  The OAuth PromEx plugin exposes `engram_prom_ex_oauth_token_total` with only
  bounded tags. Emission is covered by `EngramWeb.OAuthTokenRejectionLogTest`.
  """
  use ExUnit.Case, async: true

  alias Engram.PromEx.OAuth, as: Plugin

  defp metrics do
    Plugin.event_metrics(otp_app: :engram) |> List.wrap() |> Enum.flat_map(& &1.metrics)
  end

  test "is registered in the PromEx plugin list (else metrics never reach /metrics)" do
    assert Plugin in Engram.PromEx.plugins()
  end

  test "declares engram_prom_ex_oauth_token_total on [:engram, :oauth, :token]" do
    assert [m] = metrics()
    assert %Telemetry.Metrics.Counter{} = m
    assert m.name == [:engram, :prom_ex, :oauth, :token, :total]
    assert m.event_name == [:engram, :oauth, :token]
    assert m.tags == [:grant_type, :result, :reason]
  end
end
