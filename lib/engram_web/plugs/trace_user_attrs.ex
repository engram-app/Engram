defmodule EngramWeb.Plugs.TraceUserAttrs do
  @moduledoc """
  Stamps the current OTel request span with hashed `app.user_id` and `app.vault_id`
  so traces are filterable per user/vault, plus `plugin.version` (set by
  `RequirePluginVersion`) and `app.device_id` (`X-Device-Id`) so a flood names the
  client build that sent it (2026-11-18: 300k `POST /api/notes` from one user, no
  way to tell which plugin). Span attributes only, never metric labels: both are
  client-supplied, so the version goes through `Engram.PluginVersion.loggable/1`
  (the same filter as the log lines) and the device id is length-capped here.
  The version gate reads the raw assign, not this value. Must run AFTER Auth (and
  VaultPlug for vault_id). No-op when the assigns are absent.
  """
  @behaviour Plug
  alias Engram.Crypto.HMAC
  require OpenTelemetry.Tracer

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case attrs_for(conn) do
      [] -> :ok
      attrs -> OpenTelemetry.Tracer.set_attributes(attrs)
    end

    conn
  end

  @spec attrs_for(Plug.Conn.t()) :: [{String.t(), String.t()}]
  def attrs_for(conn) do
    []
    |> maybe_user(conn.assigns[:current_user])
    |> maybe_vault(conn.assigns[:current_vault])
    |> maybe_client(
      "plugin.version",
      Engram.PluginVersion.loggable(conn.assigns[:plugin_version])
    )
    |> maybe_client("app.device_id", EngramWeb.OriginDevice.from_conn(conn))
  end

  @max_client_attr 32

  # Client-supplied strings: printable ASCII only (versions and device ids
  # are), capped at @max_client_attr BYTES so a hostile header cannot bloat the
  # span. A grapheme cap let one grapheme carry thousands of combining marks.
  defp maybe_client(attrs, key, value) when is_binary(value) do
    if value =~ ~r/\A[\x21-\x7e]+\z/,
      do: [{key, binary_part(value, 0, min(byte_size(value), @max_client_attr))} | attrs],
      else: attrs
  end

  defp maybe_client(attrs, _key, _value), do: attrs

  # Keyed HMAC, NOT plain sha256: matches the user_id hash in log metadata
  # (Engram.Crypto.HMAC.hash_user_id/1) so trace and log user_id values correlate.
  defp maybe_user(attrs, %{id: id}) when is_binary(id),
    do: [{"app.user_id", HMAC.hash_user_id(id)} | attrs]

  defp maybe_user(attrs, _), do: attrs

  # `current_vault` (set by VaultPlug) is a `%Engram.Vaults.Vault{}` struct;
  # only its id is relevant to the span attribute.
  defp maybe_vault(attrs, %{id: id}) when is_binary(id),
    do: [{"app.vault_id", id} | attrs]

  defp maybe_vault(attrs, _), do: attrs
end
