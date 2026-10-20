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
    assert m = Enum.find(metrics(), &(&1.event_name == [:engram, :oauth, :token]))
    assert %Telemetry.Metrics.Counter{} = m
    assert m.name == [:engram, :prom_ex, :oauth, :token, :total]
    assert m.event_name == [:engram, :oauth, :token]
    assert m.tags == [:grant_type, :result, :reason, :client]
  end

  # Codes minted at consent vs `authorization_code` tokens issued, per client,
  # is the redemption ratio: a consent page that never hands back to the
  # client (#2003 on mobile) shows up as mints with no exchanges.
  test "declares engram_prom_ex_oauth_consent_total by client" do
    assert m = Enum.find(metrics(), &(&1.event_name == [:engram, :oauth, :consent]))
    assert %Telemetry.Metrics.Counter{} = m
    assert m.name == [:engram, :prom_ex, :oauth, :consent, :total]
    assert m.tags == [:client]
  end

  test "declares engram_prom_ex_cimd_fetch_total and no duration histogram" do
    assert [%Telemetry.Metrics.Counter{} = counter] =
             Enum.filter(metrics(), &(&1.event_name == [:engram, :cimd, :fetch]))

    assert counter.name == [:engram, :prom_ex, :cimd, :fetch, :total]
    assert counter.tags == [:kind, :result, :reason]
  end

  test "declares engram_prom_ex_cimd_assertion_audience_total by aud_form and client" do
    m =
      Enum.find(metrics(), &(&1.name == [:engram, :prom_ex, :cimd, :assertion_audience, :total]))

    assert %Telemetry.Metrics.Counter{} = m
    assert m.event_name == [:engram, :cimd, :assertion_audience]
    assert m.tags == [:aud_form, :client]
  end
end
