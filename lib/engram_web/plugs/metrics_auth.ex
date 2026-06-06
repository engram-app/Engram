defmodule EngramWeb.Plugs.MetricsAuth do
  @moduledoc """
  Guards the `/metrics` endpoint with a shared bearer token. Fails closed:
  if `:metrics_auth_token` is unset or empty, every request is rejected.

  Token is provided to the Grafana Agent sidecar via the same SOPS-encrypted
  prod secret store as the Grafana Cloud credentials.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    expected = Application.get_env(:engram, :metrics_auth_token)

    with token when is_binary(token) and byte_size(token) > 0 <- expected,
         ["Bearer " <> provided] <- get_req_header(conn, "authorization"),
         true <- Plug.Crypto.secure_compare(provided, token) do
      conn
    else
      _ ->
        conn
        |> send_resp(401, "")
        |> halt()
    end
  end
end
