defmodule Engram.PromEx.OAuthTest do
  @moduledoc """
  The OAuth PromEx plugin exposes `engram_prom_ex_oauth_token_total` with only
  bounded tags. Emission is covered by `EngramWeb.OAuthTokenRejectionLogTest`.
  """
  use ExUnit.Case, async: true

  alias Engram.PromEx.OAuth, as: Plugin
  alias Engram.Test.PromExMetrics

  defp metrics do
    PromExMetrics.of(Plugin) |> List.wrap() |> Enum.flat_map(& &1.metrics)
  end

  test "is registered in the PromEx plugin list (else metrics never reach /metrics)" do
    assert Plugin in Engram.PromEx.plugins()
  end

  test "declares engram_prom_ex_oauth_token_total on [:engram, :oauth, :token]" do
    assert m = Enum.find(metrics(), &(&1.event_name == [:engram, :oauth, :token]))
    assert %Telemetry.Metrics.Counter{} = m
    assert m.name == [:engram, :prom_ex, :oauth, :token, :total]
    assert m.event_name == [:engram, :oauth, :token]
    assert m.tags == [:grant_type, :result, :reason, :client, :client_agent]
  end

  # Codes minted at consent vs `authorization_code` tokens issued, per client,
  # is the redemption ratio: a consent page that never hands back to the
  # client (#2003 on mobile) shows up as mints with no exchanges.
  test "declares engram_prom_ex_oauth_consent_total by client" do
    assert m = Enum.find(metrics(), &(&1.event_name == [:engram, :oauth, :consent]))
    assert %Telemetry.Metrics.Counter{} = m
    assert m.name == [:engram, :prom_ex, :oauth, :consent, :total]
    assert m.tags == [:client, :device]
  end

  # What engram-prod-oauth-refresh-loop alerts on: kills, not the retries a
  # client sends after one (2026-10-24 triage).
  test "declares engram_prom_ex_oauth_family_revoked_total by client_agent and reason" do
    assert m = Enum.find(metrics(), &(&1.event_name == [:engram, :oauth, :family_revoked]))
    # Sum of :count so the ZeroInit boot seed exports 0, not 1.
    assert %Telemetry.Metrics.Sum{measurement: :count} = m
    assert m.name == [:engram, :prom_ex, :oauth, :family_revoked, :total]
    assert m.tags == [:client_agent, :reason]
  end

  # The direct unredeemed signal: a code the client never exchanged.
  test "declares engram_prom_ex_oauth_code_expired_total by client" do
    assert m = Enum.find(metrics(), &(&1.event_name == [:engram, :oauth, :code_expired]))
    assert %Telemetry.Metrics.Counter{} = m
    assert m.name == [:engram, :prom_ex, :oauth, :code_expired, :total]
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
