defmodule EngramWeb.Plugs.IdempotencyKeyTest do
  use EngramWeb.ConnCase, async: true

  import Engram.Factory

  alias EngramWeb.Plugs.IdempotencyKey

  setup do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    %{user: user}
  end

  defp conn_for(user), do: build_conn() |> Plug.Conn.assign(:current_user, user)

  test "missing header → 400", %{user: user} do
    conn = conn_for(user) |> IdempotencyKey.call(IdempotencyKey.init([]))
    assert conn.status == 400
    assert json_body(conn)["error"] == "missing_idempotency_key"
  end

  test "non-uuid header → 400", %{user: user} do
    conn =
      conn_for(user)
      |> put_req_header("x-idempotency-key", "not-a-uuid")
      |> IdempotencyKey.call(IdempotencyKey.init([]))

    assert conn.status == 400
  end

  test "valid uuid passes through, assigns the key", %{user: user} do
    key = Ecto.UUID.generate()

    conn =
      conn_for(user)
      |> put_req_header("x-idempotency-key", key)
      |> IdempotencyKey.call(IdempotencyKey.init([]))

    refute conn.halted
    assert conn.assigns.idempotency_key == key
  end

  test "replay returns cached response and halts", %{user: user} do
    key = Ecto.UUID.generate()
    Engram.Idempotency.remember(user, key, %{status: 200, body: %{cached: true}})

    conn =
      conn_for(user)
      |> put_req_header("x-idempotency-key", key)
      |> IdempotencyKey.call(IdempotencyKey.init([]))

    assert conn.halted
    assert json_body(conn) == %{"cached" => true}
  end

  test "another user's key does not replay — batch would re-execute", %{user: user} do
    key = Ecto.UUID.generate()
    Engram.Idempotency.remember(user, key, %{status: 200, body: %{cached: true}})

    other = insert(:user)
    {:ok, other} = Engram.Crypto.ensure_user_dek(other)

    conn =
      conn_for(other)
      |> put_req_header("x-idempotency-key", key)
      |> IdempotencyKey.call(IdempotencyKey.init([]))

    refute conn.halted
    assert conn.assigns.idempotency_key == key
  end

  defp json_body(conn), do: conn.resp_body |> Jason.decode!()
end
