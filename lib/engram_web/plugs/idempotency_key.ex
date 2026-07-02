defmodule EngramWeb.Plugs.IdempotencyKey do
  @moduledoc """
  Enforces `X-Idempotency-Key` header on batch endpoints. Validates UUID
  shape. On replay (key already recorded), returns the cached response
  and halts before the controller action runs.
  """
  import Plug.Conn
  alias Engram.Idempotency

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "x-idempotency-key") do
      [key] -> validate(conn, key)
      _ -> reject(conn, "missing_idempotency_key")
    end
  end

  defp validate(conn, key) do
    case Ecto.UUID.cast(key) do
      {:ok, key} -> maybe_replay(conn, key)
      :error -> reject(conn, "invalid_idempotency_key")
    end
  end

  defp maybe_replay(conn, key) do
    # User-scoped: the key namespace is per authenticated user (Auth runs
    # before this plug), so one tenant can never replay another's response.
    case Idempotency.lookup(conn.assigns.current_user, key) do
      {:ok, %{status: status, body: body}} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(body))
        |> halt()

      :miss ->
        assign(conn, :idempotency_key, key)
    end
  end

  defp reject(conn, code) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(400, Jason.encode!(%{error: code}))
    |> halt()
  end
end
