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
end
