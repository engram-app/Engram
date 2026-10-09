defmodule EngramWeb.AttachmentsSlowUploadTest do
  @moduledoc """
  Raw attachment uploads over a real Bandit socket from slow clients.

  Bandit's HTTP/1 body read is a passive recv of `read_length` bytes under one
  `read_timeout`, so the timeout bounds the time to receive a whole
  `read_length`, not the time between bytes. With a 1 MB read_length and the
  15 s default, any uplink under ~70 KB/s could never upload a file over 1 MB
  (prod 2026-10-09, Sentry ENGRAM-BACKEND-W). Plug.Test bypasses Bandit, so
  these drive the real endpoint over :gen_tcp with the timeout shortened.
  """
  use EngramWeb.ConnCase, async: false

  @read_timeout 500

  setup do
    user = insert(:user)
    insert(:subscription, user: user, tier: "pro", status: "active")
    insert(:vault, user: user, is_default: true)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    grant_api_write!(user)

    Application.put_env(:engram, :body_read_timeout, @read_timeout)
    on_exit(fn -> Application.delete_env(:engram, :body_read_timeout) end)

    test = self()

    {:ok, pid} =
      start_supervised(
        {Bandit, plug: EngramWeb.Endpoint, port: 0, ip: :loopback, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    id = "slow-upload-#{inspect(make_ref())}"

    :telemetry.attach(
      id,
      [:bandit, :request, :stop],
      fn _event, _measure, meta, _ -> send(test, {:bandit_stop, meta[:error]}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    on_exit(fn -> :gen_tcp.close(sock) end)
    %{sock: sock, api_key: api_key}
  end

  defp post_head(api_key, length) do
    "POST /api/attachments?path=slow.png&mtime=1.0 HTTP/1.1\r\n" <>
      "host: localhost\r\nauthorization: Bearer #{api_key}\r\n" <>
      "content-type: application/octet-stream\r\ncontent-length: #{length}\r\n\r\n"
  end

  defp response(sock) do
    {:ok, data} = :gen_tcp.recv(sock, 0, 5_000)
    [status | _] = String.split(data, "\r\n")
    {status, data}
  end

  # 768 KB in 16 KB pieces every 40 ms: ~1.9 s in all, so one read of the whole
  # body outlasts the 500 ms timeout even after the pipeline's own latency, but
  # each 64 KB arrives in ~160 ms.
  test "a slow but steady client uploads past the read timeout", %{sock: sock, api_key: key} do
    body = :crypto.strong_rand_bytes(768 * 1024)
    :ok = :gen_tcp.send(sock, post_head(key, byte_size(body)))

    for <<piece::binary-size(16 * 1024) <- body>> do
      Process.sleep(40)
      :ok = :gen_tcp.send(sock, piece)
    end

    {status, data} = response(sock)
    assert status == "HTTP/1.1 200 OK", data
    assert_receive {:bandit_stop, nil}, 2_000
  end

  test "a stalled client still gets a 408 and raises nothing", %{sock: sock, api_key: key} do
    :ok = :gen_tcp.send(sock, [post_head(key, 256 * 1024), :binary.copy("a", 1_000)])

    {status, data} = response(sock)
    assert status == "HTTP/1.1 408 Request Timeout", data
    assert data =~ "request body timed out"
    assert_receive {:bandit_stop, nil}, 2_000
  end
end
