defmodule Engram.Logger.JsonFormatTest do
  use ExUnit.Case, async: true

  # This test exercises the logger_json Basic formatter DIRECTLY (build it +
  # format a synthetic :logger event), so it is independent of MIX_ENV — the
  # prod config wiring is verified separately by `MIX_ENV=prod mix compile`.
  #
  # logger_json 7.0.4 Basic formatter output shape (verified against
  # deps/logger_json/lib/logger_json/formatters/basic.ex):
  #   - top-level keys: "time", "severity", "message"
  #   - ALL :logger metadata is NESTED under a "metadata" object
  #
  # So for Loki `| json` queries the field paths are:
  #   metadata_category   (from "metadata"."category")
  #   metadata_loki_ship  (from "metadata"."loki_ship")
  # i.e. category and loki_ship live under metadata.*, NOT at the top level.
  test "Basic formatter encodes message + category + loki_ship metadata as JSON" do
    # {module, config} tuple — same value shape used in config/prod.exs
    {formatter_mod, formatter_cfg} = LoggerJSON.Formatters.Basic.new(metadata: :all)

    event = %{
      level: :info,
      msg: {:string, "note synced"},
      meta: %{
        category: :sync,
        loki_ship: true,
        request_id: "F-abc123"
      }
    }

    iodata = formatter_mod.format(event, formatter_cfg)
    json = iodata |> IO.iodata_to_binary() |> String.trim()

    decoded = Jason.decode!(json)

    assert decoded["message"] == "note synced"
    assert decoded["severity"] == "info"
    # metadata is nested under "metadata" by the Basic formatter
    assert decoded["metadata"]["category"] == "sync"
    assert decoded["metadata"]["loki_ship"] == true
    # request_id rides along under metadata too (metadata: :all)
    assert decoded["metadata"]["request_id"] == "F-abc123"
  end

  # Mirrors the option in config/prod.exs. Same convention as the test above:
  # the formatter is exercised directly so this is MIX_ENV-independent, and
  # `MIX_ENV=prod mix compile` is what proves the wiring matches.
  @prod_metadata {:all_except, [:__sentry__]}

  test "the Sentry request-context blob is excluded from prod log lines" do
    {formatter_mod, formatter_cfg} = LoggerJSON.Formatters.Basic.new(metadata: @prod_metadata)

    event = %{
      level: :warning,
      msg: {:string, "POST 401 in 0ms"},
      meta: %{
        category: :http,
        status: 401,
        loki_ship: true,
        # What Sentry.PlugContext actually injects. The mTLS leaf header is a
        # ~2.5KB base64 PEM, identical on every request behind the ALB, and it
        # was riding every single log line under `metadata: :all`.
        __sentry__: %{
          request: %{
            url: "http://api.engram.page/api/attachments",
            headers: %{
              "x-amzn-mtls-clientcert-leaf" =>
                "-----BEGIN%20CERTIFICATE-----" <> String.duplicate("MIIEeDCCAmCg", 200),
              "cf-connecting-ip" => "203.0.113.7",
              "authorization" => "Bearer secret-token"
            }
          }
        }
      }
    }

    json = event |> formatter_mod.format(formatter_cfg) |> IO.iodata_to_binary() |> String.trim()

    # The blob is gone, and so is everything nested inside it.
    refute json =~ "__sentry__"
    refute json =~ "CERTIFICATE"
    refute json =~ "cf-connecting-ip"
    refute json =~ "secret-token"

    # ...while the fields we actually triage on still ship.
    decoded = Jason.decode!(json)
    assert decoded["message"] == "POST 401 in 0ms"
    assert decoded["metadata"]["category"] == "http"
    assert decoded["metadata"]["status"] == 401
    assert decoded["metadata"]["loki_ship"] == true
  end
end
