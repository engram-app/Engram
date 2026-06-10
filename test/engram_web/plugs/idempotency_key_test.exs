defmodule EngramWeb.Plugs.IdempotencyKeyTest do
  use EngramWeb.ConnCase, async: false
  alias EngramWeb.Plugs.IdempotencyKey

  setup do
    case Engram.Idempotency.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  test "missing header → 400" do
    conn = build_conn() |> IdempotencyKey.call(IdempotencyKey.init([]))
    assert conn.status == 400
    assert json_body(conn)["error"] == "missing_idempotency_key"
  end

  test "non-uuid header → 400" do
    conn =
      build_conn()
      |> put_req_header("x-idempotency-key", "not-a-uuid")
      |> IdempotencyKey.call(IdempotencyKey.init([]))

    assert conn.status == 400
  end

  test "valid uuid passes through, assigns the key" do
    key = Ecto.UUID.generate()

    conn =
      build_conn()
      |> put_req_header("x-idempotency-key", key)
      |> IdempotencyKey.call(IdempotencyKey.init([]))

    refute conn.halted
    assert conn.assigns.idempotency_key == key
  end

  test "replay returns cached response and halts" do
    key = Ecto.UUID.generate()
    Engram.Idempotency.remember(key, %{status: 200, body: %{cached: true}})

    conn =
      build_conn()
      |> put_req_header("x-idempotency-key", key)
      |> IdempotencyKey.call(IdempotencyKey.init([]))

    assert conn.halted
    assert json_body(conn) == %{"cached" => true}
  end

  defp json_body(conn), do: conn.resp_body |> Jason.decode!()
end
