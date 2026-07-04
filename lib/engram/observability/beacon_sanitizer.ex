defmodule Engram.Observability.BeaconSanitizer do
  @moduledoc """
  Validates and normalizes an untrusted client beacon entry into a shape
  safe for `Engram.Observability.ClientSpan.record/1`. Enforces the
  cardinality/PII contract: only allowlisted attributes, only known span
  names, hex-valid ids, and sane client timing (clamped against the server
  clock). Client beacons are authed but still untrusted, so this is the
  security core.
  """

  @allowed_attributes ["engram.surface", "engram.event_type", "engram.duration_ms"]
  @allowed_names ["obsidian.push", "browser.live_sync.render"]
  @max_duration_us 30_000_000
  @max_skew_us 300_000_000

  @spec allowed_attributes() :: [String.t()]
  def allowed_attributes, do: @allowed_attributes

  @spec sanitize(map(), integer()) :: {:ok, map()} | {:error, atom()}
  def sanitize(entry, now_us) when is_map(entry) do
    with {:ok, trace_id} <- hex(entry["trace_id"], 32, :bad_trace_id),
         {:ok, parent_span_id} <- hex(entry["parent_span_id"], 16, :bad_parent_span_id),
         {:ok, name} <- name(entry["name"]),
         {:ok, start_us, end_us} <- timing(entry["start_us"], entry["end_us"], now_us) do
      {:ok,
       %{
         traceparent: "00-#{trace_id}-#{parent_span_id}-01",
         name: name,
         start_us: start_us,
         end_us: end_us,
         attributes: attributes(entry["attributes"])
       }}
    end
  end

  defp hex(value, len, err) when is_binary(value) do
    down = String.downcase(value)

    if String.length(down) == len and String.match?(down, ~r/\A[0-9a-f]+\z/),
      do: {:ok, down},
      else: {:error, err}
  end

  defp hex(_, _, err), do: {:error, err}

  defp name(value) when value in @allowed_names, do: {:ok, value}
  defp name(_), do: {:error, :bad_name}

  defp timing(s, e, now_us) when is_integer(s) and is_integer(e) do
    cond do
      e < s -> {:error, :bad_timing}
      e - s > @max_duration_us -> {:error, :bad_timing}
      abs(now_us - s) > @max_skew_us -> {:error, :clock_skew}
      true -> {:ok, s, e}
    end
  end

  defp timing(_, _, _), do: {:error, :bad_timing}

  defp attributes(attrs) when is_map(attrs), do: Map.take(attrs, @allowed_attributes)
  defp attributes(_), do: %{}
end
