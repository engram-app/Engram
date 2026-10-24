defmodule Engram.Workers.DropUserVectorsTest do
  @moduledoc """
  The account-delete Qdrant drop, moved out of the DELETE /api/me request.
  It used to run inline with a 5s timeout, twice (soft + hard), and its
  failures were swallowed, so a slow Qdrant held the request past the e2e
  client's 10s read timeout and nothing ever retried the drop.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Workers.DropUserVectors

  setup do
    bypass = Bypass.open()
    Engram.ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    {:ok, calls} = Agent.start_link(fn -> [] end)
    {:ok, bypass: bypass, calls: calls}
  end

  defp stub_delete(bypass, calls, status) do
    Bypass.stub(bypass, "POST", "/collections/:col/points/delete", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      Agent.update(calls, &[Jason.decode!(body) | &1])
      Plug.Conn.send_resp(conn, status, ~s({"status":"ok","result":{}}))
    end)
  end

  test "drops every point owned by a purged user", %{bypass: bypass, calls: calls} do
    user_id = Ecto.UUID.generate()
    stub_delete(bypass, calls, 200)

    assert :ok = perform_job(DropUserVectors, %{"user_id" => user_id})

    expected =
      %{must: [Engram.Vector.Qdrant.match_filter(:user, user_id)]}
      |> Jason.encode!()
      |> Jason.decode!()

    assert [%{"filter" => ^expected}] = Agent.get(calls, & &1)
  end

  test "drops the points of a soft-deleted user", %{bypass: bypass, calls: calls} do
    user =
      insert(:user)
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
      |> Repo.update!(skip_tenant_check: true)

    stub_delete(bypass, calls, 200)

    assert :ok = perform_job(DropUserVectors, %{"user_id" => user.id})
    assert length(Agent.get(calls, & &1)) == 1
  end

  test "returns an error on a Qdrant failure so Oban retries", %{bypass: bypass, calls: calls} do
    stub_delete(bypass, calls, 503)

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:error, _} = perform_job(DropUserVectors, %{"user_id" => Ecto.UUID.generate()})
    end)
  end

  # A job outliving a delete that never took effect must not wipe a live
  # account's search index.
  test "never touches a live account", %{bypass: bypass, calls: calls} do
    user = insert(:user)
    stub_delete(bypass, calls, 200)

    assert {:cancel, :user_live} = perform_job(DropUserVectors, %{"user_id" => user.id})
    assert Agent.get(calls, & &1) == []
  end

  test "enqueue/1 dedupes while a drop for the same user is pending" do
    user_id = Ecto.UUID.generate()

    assert {:ok, _} = DropUserVectors.enqueue(user_id)
    assert {:ok, %{conflict?: true}} = DropUserVectors.enqueue(user_id)

    assert [_] = all_enqueued(worker: DropUserVectors, args: %{"user_id" => user_id})
  end

  # A hard delete committing while the soft-delete job is mid-call must queue
  # its own drop, not dedupe into a job that started before the purge.
  test "enqueue/1 does not dedupe against an executing drop" do
    user_id = Ecto.UUID.generate()
    {:ok, first} = DropUserVectors.enqueue(user_id)

    Repo.update_all(from(j in Oban.Job, where: j.id == ^first.id), set: [state: "executing"])

    assert {:ok, %{conflict?: false} = second} = DropUserVectors.enqueue(user_id)
    refute second.id == first.id
  end
end
