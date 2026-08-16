defmodule Engram.Logger.RescueReasonSinkTest do
  @moduledoc """
  End-to-end proof, at the SINK, that a rescued exception's reason cannot carry
  note content into Loki or CloudWatch.

  Why this exists rather than another `capture_log` assertion: `capture_log`
  renders the DEV text formatter, whose `metadata:` allowlist in
  config/config.exs does not contain `:error`. A leak in `error:` metadata is
  therefore INVISIBLE to capture_log and fully visible in prod — a test that
  passes for a reason that does not hold in production.

  Prod uses `{LoggerJSON.Formatters.Basic, metadata: {:all_except, [...]}}`
  (config/prod.exs) — an emit-everything-but-a-few-keys list. So this builds the
  real event, runs the real `RedactFilter`, and formats with the real prod
  formatter config.
  """
  use ExUnit.Case, async: true

  alias Engram.Logger.Metadata
  alias Engram.Logger.RedactFilter

  @secret "Dear diary, the biopsy came back positive."

  defp prod_line(meta, message) do
    event = %{level: :error, msg: {:string, message}, meta: meta}
    filtered = RedactFilter.filter(event, [])

    {mod, cfg} = LoggerJSON.Formatters.Basic.new(metadata: {:all_except, [:__sentry__]})

    mod.format(filtered, cfg) |> IO.iodata_to_binary() |> String.trim() |> Jason.decode!()
  end

  test "the reason a rescue logs never reaches the prod sink with note content" do
    e = %CaseClauseError{term: {:parsed, @secret}}
    reason = Metadata.safe_reason(e)

    meta =
      Metadata.with_category(:error, :sync, path: "Medical/biopsy.md", error: reason)
      |> Map.new()

    decoded = prod_line(meta, "batch entry raised, degrading note path_hmac=abc (#{reason})")
    line = Jason.encode!(decoded)

    refute line =~ "biopsy"
    refute line =~ @secret
    # The class survives, so the line still says what broke.
    assert decoded["metadata"]["error"] == "CaseClauseError"
    # And the path is redacted by key, as it already was.
    assert decoded["metadata"]["path"] == "[REDACTED]"
  end

  # The failing half, stated as a test so the reason for safe_reason/1 is not
  # re-derived: RedactFilter has no `:error` key, so putting a raw message there
  # is NOT gated. This asserts the property that made the earlier fix wrong.
  test "RedactFilter does not gate the :error key, which is why the type filter exists" do
    meta =
      Metadata.with_category(:error, :sync,
        error: Exception.message(%CaseClauseError{term: @secret})
      )
      |> Map.new()

    line = prod_line(meta, "batch entry raised") |> Jason.encode!()

    assert line =~ "biopsy",
           "RedactFilter now scrubs :error — safe_reason/1 may be redundant, re-check it"
  end
end
