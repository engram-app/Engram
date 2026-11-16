defmodule Engram.QdrantStubTest do
  use ExUnit.Case, async: true

  # IndexingFloorTest flaked with `Req.TransportError{reason: :closed}` on a
  # 2-3 MB floor upsert: its stub answered without reading the body, and
  # cowboy (Bypass) closes the connection when a handler leaves over 1 MB of
  # the body unread. Raw TCP, so no client pool hides the close.
  test "ack/1 reads a multi-MB body, so the connection survives the answer" do
    bypass = Bypass.open()
    Bypass.stub(bypass, :any, :any, &Engram.QdrantStub.ack/1)

    {:ok, sock} = :gen_tcp.connect(~c"localhost", bypass.port, [:binary, active: false])
    body = :binary.copy("x", 3 * 1024 * 1024)

    head =
      "PUT /collections/c/points HTTP/1.1\r\nhost: localhost\r\n" <>
        "content-type: application/json\r\ncontent-length: #{byte_size(body)}\r\n\r\n"

    sender = Task.async(fn -> :gen_tcp.send(sock, [head, body]) end)

    assert {:ok, "HTTP/1.1 200" <> _} = :gen_tcp.recv(sock, 0, 10_000)
    assert :ok = Task.await(sender, 10_000)
    # Still open: nothing to read, no close.
    assert {:error, :timeout} = :gen_tcp.recv(sock, 0, 300)
  end
end
