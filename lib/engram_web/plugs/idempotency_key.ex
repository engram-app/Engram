defmodule EngramWeb.Plugs.IdempotencyKey do
  @moduledoc """
  Enforces `X-Idempotency-Key` header on batch endpoints. Validates UUID
  shape. On replay (key already recorded), returns the cached response
  and halts before the controller action runs.
  """
  import Plug.Conn
  alias Engram.Idempotency
  alias EngramWeb.Plugs.Halt

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

  @doc """
  Caches this request's response under the key and scope `call/2` assigned.
  The batch actions call this on success.
  """
  def remember(conn, response) do
    Idempotency.remember(
      conn.assigns.current_user,
      conn.assigns.idempotency_key,
      scope(conn),
      response
    )
  end

  defp maybe_replay(conn, key) do
    # Scoped to user, vault and route (#1869): VaultPlug has already checked
    # current_vault against the credential, so a credential restricted to
    # vault B can never replay a response cached for vault A.
    case Idempotency.lookup(conn.assigns.current_user, key, scope(conn)) do
      {:ok, %{status: status, body: body}} ->
        Halt.json(conn, status, body)

      :miss ->
        assign(conn, :idempotency_key, key)
    end
  end

  defp scope(conn),
    do: %{vault_id: conn.assigns.current_vault.id, route: "#{conn.method} #{conn.request_path}"}

  defp reject(conn, code) do
    Halt.json(conn, 400, %{error: code})
  end
end
