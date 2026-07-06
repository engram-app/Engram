defmodule EngramWeb.Plugs.TraceUserAttrs do
  @moduledoc """
  Stamps the current OTel request span with hashed `app.user_id` and `app.vault_id`
  so traces are filterable per user/vault. Must run AFTER Auth (and VaultPlug for
  vault_id). No-op when the assigns are absent.
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
  end

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
