defmodule Engram.Observability.BeaconSanitizerTest do
  use ExUnit.Case, async: true

  alias Engram.Observability.BeaconSanitizer, as: S

  @now_us 1_783_200_000_000_000

  defp base do
    %{
      "trace_id" => "11111111111111111111111111111111",
      "parent_span_id" => "2222222222222222",
      "name" => "obsidian.push",
      "start_us" => @now_us - 5_000,
      "end_us" => @now_us,
      "attributes" => %{"engram.surface" => "obsidian", "engram.event_type" => "upsert"}
    }
  end

  test "valid entry produces a traceparent and keeps allowlisted attrs" do
    assert {:ok, out} = S.sanitize(base(), @now_us)
    assert out.traceparent == "00-11111111111111111111111111111111-2222222222222222-01"
    assert out.name == "obsidian.push"
    assert out.attributes == %{"engram.surface" => "obsidian", "engram.event_type" => "upsert"}
  end

  test "drops non-allowlisted attributes (no content/path/user leakage)" do
    entry =
      put_in(base()["attributes"], %{
        "engram.surface" => "web",
        "content" => "secret",
        "path" => "/x"
      })

    assert {:ok, out} = S.sanitize(entry, @now_us)
    assert out.attributes == %{"engram.surface" => "web"}
  end

  test "rejects bad hex ids" do
    assert {:error, :bad_trace_id} = S.sanitize(put_in(base()["trace_id"], "xyz"), @now_us)

    assert {:error, :bad_parent_span_id} =
             S.sanitize(put_in(base()["parent_span_id"], "short"), @now_us)
  end

  test "rejects inverted or oversized durations" do
    assert {:error, :bad_timing} =
             S.sanitize(%{base() | "start_us" => @now_us, "end_us" => @now_us - 1}, @now_us)

    assert {:error, :bad_timing} =
             S.sanitize(
               %{base() | "start_us" => @now_us - 40_000_000_000, "end_us" => @now_us},
               @now_us
             )
  end

  test "rejects timestamps far from server clock (skew/spoof)" do
    assert {:error, :clock_skew} =
             S.sanitize(
               %{base() | "start_us" => @now_us - 600_000_000, "end_us" => @now_us - 600_000_000},
               @now_us
             )
  end

  test "rejects an unknown span name" do
    assert {:error, :bad_name} = S.sanitize(put_in(base()["name"], "arbitrary.span"), @now_us)
  end

  test "rejects non-map entry (crash safety)" do
    assert {:error, :invalid_entry} = S.sanitize("not a map", @now_us)
    assert {:error, :invalid_entry} = S.sanitize(123, @now_us)
    assert {:error, :invalid_entry} = S.sanitize([1, 2, 3], @now_us)
  end

  test "drops oversized string values in attributes (value smuggling)" do
    oversized = String.duplicate("x", 200)

    entry =
      put_in(base()["attributes"], %{
        "engram.surface" => oversized,
        "engram.event_type" => "upsert"
      })

    assert {:ok, out} = S.sanitize(entry, @now_us)
    assert out.attributes == %{"engram.event_type" => "upsert"}
  end

  test "keeps short string and numeric values in attributes" do
    entry =
      put_in(base()["attributes"], %{
        "engram.surface" => "obsidian",
        "engram.duration_ms" => 12.5,
        "engram.event_type" => "upsert"
      })

    assert {:ok, out} = S.sanitize(entry, @now_us)

    assert out.attributes == %{
             "engram.surface" => "obsidian",
             "engram.duration_ms" => 12.5,
             "engram.event_type" => "upsert"
           }
  end
end
