defmodule Engram.Workers.PurgeUserVectorsTest do
  use Engram.DataCase, async: true
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Workers.PurgeUserVectors

  setup do
    bypass = Bypass.open()
    Engram.ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    {:ok, bypass: bypass, user_id: Ecto.UUID.generate()}
  end

  test "deletes every point filtered on the user", %{bypass: bypass, user_id: user_id} do
    test_pid = self()

    Bypass.expect_once(bypass, "POST", "/collections/:col/points/delete", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:filter, Jason.decode!(body)["filter"]})
      Plug.Conn.send_resp(conn, 200, ~s({"status":"ok","result":{}}))
    end)

    assert :ok = perform_job(PurgeUserVectors, %{"user_id" => user_id})

    expected = Engram.Vector.Qdrant.match_filter(:user, user_id) |> Jason.encode!()
    assert_received {:filter, %{"must" => [filter]}}
    assert filter == Jason.decode!(expected)
  end

  # Privacy: a failed purge must surface as an error so Oban retries it,
  # never as a swallowed :ok that leaves a deleted user's vectors behind.
  test "a failed delete returns an error, so Oban retries it", %{
    bypass: bypass,
    user_id: user_id
  } do
    Bypass.stub(bypass, "POST", "/collections/:col/points/delete", fn conn ->
      Plug.Conn.send_resp(conn, 500, ~s({"status":{"error":"boom"}}))
    end)

    assert {:error, _} = perform_job(PurgeUserVectors, %{"user_id" => user_id})
  end
end
