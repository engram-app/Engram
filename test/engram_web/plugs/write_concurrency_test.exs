defmodule EngramWeb.Plugs.WriteConcurrencyTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Engram.Vaults.SeqGate
  alias EngramWeb.Plugs.WriteConcurrency

  setup do
    Application.put_env(:engram, :write_inflight_cap, 2)
    on_exit(fn -> Application.delete_env(:engram, :write_inflight_cap) end)
    %{a: %{id: Ecto.UUID.generate()}, b: %{id: Ecto.UUID.generate()}}
  end

  defp req(method, user, path \\ "/api/attachments/x.png") do
    conn(method, path) |> assign(:current_user, user) |> WriteConcurrency.call([])
  end

  # Holds a slot from a separate process, as a slow in-flight request would.
  defp hold(user) do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, _} = SeqGate.enter_user(user.id)
        send(parent, :in)
        receive do: (:done -> :ok)
      end)

    assert_receive :in
    pid
  end

  test "user at cap gets 429 + retry-after while another user is unaffected", %{a: a, b: b} do
    _holders = [hold(a), hold(a)]

    denied = req("DELETE", a)
    assert denied.status == 429
    assert denied.halted
    assert get_resp_header(denied, "retry-after") == ["1"]

    refute req("DELETE", b).halted
  end

  test "reads and MCP posts are exempt", %{a: a} do
    [hold(a), hold(a)]
    refute req("GET", a).halted
    refute req("POST", a, "/api/mcp").halted
  end

  test "the slot frees when the response is sent and when the holder dies", %{a: a} do
    h1 = hold(a)
    _h2 = hold(a)
    assert req("DELETE", a).status == 429

    Process.exit(h1, :kill)
    Process.sleep(50)

    conn = req("DELETE", a)
    refute conn.halted
    send_resp(conn, 200, "ok")
    Process.sleep(50)
    refute req("DELETE", a).halted
  end
end
