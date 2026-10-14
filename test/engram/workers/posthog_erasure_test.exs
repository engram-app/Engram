defmodule Engram.Workers.PostHogErasureTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Workers.PostHogErasure

  setup do
    keys = [:posthog_erasure_api_key, :posthog_project_id, :posthog_host]
    prev = Map.new(keys, &{&1, Application.get_env(:engram, &1)})

    on_exit(fn ->
      for {k, v} <- prev,
          do:
            if(is_nil(v),
              do: Application.delete_env(:engram, k),
              else: Application.put_env(:engram, k, v)
            )
    end)

    bypass = Bypass.open()
    Application.put_env(:engram, :posthog_erasure_api_key, "phx_test_key")
    Application.put_env(:engram, :posthog_project_id, "1")
    Application.put_env(:engram, :posthog_host, "http://localhost:#{bypass.port}")
    {:ok, bypass: bypass}
  end

  defp persons(bypass, results_by_id) do
    Bypass.expect(bypass, "GET", "/api/projects/1/persons/", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      results = Map.get(results_by_id, conn.query_params["distinct_id"], [])

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{results: results}))
    end)
  end

  test "deletes the person behind every id", %{bypass: bypass} do
    persons(bypass, %{"a" => [%{id: "p-a"}], "b" => [%{id: "p-b"}]})
    parent = self()

    Bypass.expect(bypass, "DELETE", "/api/projects/1/persons/:id/", fn conn ->
      send(parent, {:deleted, conn.request_path, conn.query_string})
      Plug.Conn.resp(conn, 204, "")
    end)

    assert :ok = perform_job(PostHogErasure, %{"distinct_ids" => ["a", "b"]})
    assert_received {:deleted, "/api/projects/1/persons/p-a/", "delete_events=true"}
    assert_received {:deleted, "/api/projects/1/persons/p-b/", "delete_events=true"}
  end

  test "an id with no person is success", %{bypass: bypass} do
    persons(bypass, %{})
    assert :ok = perform_job(PostHogErasure, %{"distinct_ids" => ["missing"]})
  end

  test "a failed delete fails the job so Oban retries", %{bypass: bypass} do
    persons(bypass, %{"a" => [%{id: "p-a"}]})
    Bypass.expect(bypass, "DELETE", "/api/projects/1/persons/:id/", &Plug.Conn.resp(&1, 503, ""))

    assert {:error, _} = perform_job(PostHogErasure, %{"distinct_ids" => ["a"]})
  end
end
