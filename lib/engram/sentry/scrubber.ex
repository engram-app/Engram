defmodule Engram.Sentry.Scrubber do
  @moduledoc """
  Sentry `:before_send` callback. Strips PII from event payloads before
  they leave the process for Sentry's API.

  Paddle webhooks echo customer email/address/phone — make sure none of
  that reaches Sentry. The conservative posture is:

    * **Drop `event.request` entirely.** Auto-instrumentation from
      `Sentry.PlugContext` populates Authorization headers, session
      cookies, and query strings with embedded tokens/emails — none of
      it carries signal you can't get from structured logger metadata.
    * **Recurse through `event.extra`, `event.user`, `event.tags`,
      `event.contexts`, and `event.breadcrumbs[*].data`**, redacting any
      key whose name contains an `@pii_substrings` token.

  Deeper redaction (e.g. regex-scanning `event.message` /
  `event.exception[*].value`) is out of scope here — logs upstream of
  this scrubber already pass through `Engram.Logger.RedactFilter`, so
  message strings reaching Sentry should already be redacted. The
  scrubber is the last line of defense for *structured* payload fields.
  """

  @pii_substrings ~w(email phone address card iban pan ssn)

  # Sentry's LoggerHandler lifts a crashed GenServer's inspected last message
  # and state into `extra`. For a channel those are the client payload and the
  # socket (current_user, raw-id topics). The translator already truncates
  # their strings (`translator_inspect_opts`); dropping them is the backstop.
  @crash_extras ~w(last_message genserver_state pid_which_sent_last_message crash_reason)
  @redacted "[redacted]"

  @spec scrub(Sentry.Event.t()) :: Sentry.Event.t()
  def scrub(%Sentry.Event{} = event) do
    %{
      event
      | request: nil,
        extra: event.extra |> drop_crash_extras() |> redact_map(),
        user: redact_map(event.user),
        tags: redact_map(event.tags),
        contexts: redact_map(event.contexts),
        breadcrumbs: redact_breadcrumbs(event.breadcrumbs)
    }
  end

  defp drop_crash_extras(extra) when is_map(extra) do
    Map.drop(extra, @crash_extras ++ Enum.map(@crash_extras, &String.to_atom/1))
  end

  defp drop_crash_extras(extra), do: extra

  defp redact_map(nil), do: nil

  defp redact_map(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} ->
      cond do
        pii_key?(k) -> {k, @redacted}
        is_map(v) and not is_struct(v) -> {k, redact_map(v)}
        is_list(v) -> {k, redact_list(v)}
        true -> {k, v}
      end
    end)
  end

  defp redact_map(other), do: other

  defp redact_list(list) when is_list(list) do
    Enum.map(list, fn
      v when is_map(v) and not is_struct(v) -> redact_map(v)
      v when is_list(v) -> redact_list(v)
      v -> v
    end)
  end

  defp redact_breadcrumbs(nil), do: nil
  defp redact_breadcrumbs([]), do: []

  defp redact_breadcrumbs(crumbs) when is_list(crumbs) do
    Enum.map(crumbs, &redact_breadcrumb/1)
  end

  defp redact_breadcrumb(%Sentry.Interfaces.Breadcrumb{} = crumb) do
    %{crumb | data: redact_map(crumb.data)}
  end

  defp redact_breadcrumb(%{data: data} = crumb) when is_map(crumb) do
    %{crumb | data: redact_map(data)}
  end

  defp redact_breadcrumb(other), do: other

  defp pii_key?(key) when is_atom(key), do: pii_key?(Atom.to_string(key))

  defp pii_key?(key) when is_binary(key) do
    downcased = String.downcase(key)
    Enum.any?(@pii_substrings, &String.contains?(downcased, &1))
  end

  defp pii_key?(_), do: false
end
