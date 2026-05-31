defmodule Engram.Sentry.Scrubber do
  @moduledoc """
  Sentry `:before_send` callback. Strips PII from event payloads before
  they leave the process for Sentry's API.

  Paddle webhooks echo customer email/address/phone — make sure none of
  that reaches Sentry. The conservative default is to drop the raw
  request body entirely; structured logger metadata supplies actionable
  context. The `extra` map is walked recursively and any key containing
  one of `@pii_substrings` is replaced with `"[redacted]"`.
  """

  @pii_substrings ~w(email phone address card iban pan ssn)

  @spec scrub(Sentry.Event.t()) :: Sentry.Event.t()
  def scrub(%Sentry.Event{} = event) do
    event
    |> drop_request_data()
    |> redact_extra()
  end

  defp drop_request_data(%Sentry.Event{request: %Sentry.Interfaces.Request{} = req} = event) do
    %{event | request: %{req | data: nil}}
  end

  defp drop_request_data(event), do: event

  defp redact_extra(%Sentry.Event{extra: extra} = event) when is_map(extra) do
    %{event | extra: redact_map(extra)}
  end

  defp redact_extra(event), do: event

  defp redact_map(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      cond do
        pii_key?(k) -> {k, "[redacted]"}
        is_map(v) -> {k, redact_map(v)}
        is_list(v) -> {k, redact_list(v)}
        true -> {k, v}
      end
    end)
  end

  defp redact_list(list) when is_list(list) do
    Enum.map(list, fn
      v when is_map(v) -> redact_map(v)
      v when is_list(v) -> redact_list(v)
      v -> v
    end)
  end

  defp pii_key?(key) when is_atom(key), do: pii_key?(Atom.to_string(key))

  defp pii_key?(key) when is_binary(key) do
    downcased = String.downcase(key)
    Enum.any?(@pii_substrings, &String.contains?(downcased, &1))
  end

  defp pii_key?(_), do: false
end
