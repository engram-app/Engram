defmodule Engram.Vector.QdrantReqOptsTest do
  @moduledoc """
  Per-purpose Req options: user-facing search must fail fast (short
  receive_timeout, NO retries — a Qdrant brownout must not pin `/api/search`
  requests for 30s x 4 attempts), while indexing keeps the patient defaults
  (Oban retries the whole job anyway, but transient in-call retries save
  attempts).
  """
  use ExUnit.Case, async: true

  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant

  describe "req_opts/1" do
    test "search purpose: short timeout, retries disabled" do
      opts = Qdrant.req_opts(:search)

      assert opts[:retry] == false
      assert opts[:max_retries] == 0
      assert opts[:receive_timeout] <= 5_000
    end

    test "indexing purpose: patient timeout, retry follows :qdrant_retry config" do
      ServiceConfig.put_override(:qdrant_retry, :transient)
      opts = Qdrant.req_opts(:indexing)

      assert opts[:retry] == :transient
      assert opts[:max_retries] == 3
      assert opts[:receive_timeout] == 30_000
    end
  end

  describe "search path behavior" do
    setup do
      bypass = Bypass.open()
      ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
      # Force retries ON so a regression (search using the indexing opts)
      # shows up as extra attempts.
      ServiceConfig.put_override(:qdrant_retry, :transient)
      %{bypass: bypass}
    end

    test "search makes exactly one attempt on a 503", %{bypass: bypass} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Bypass.stub(bypass, "POST", "/collections/c/points/query", fn conn ->
        Agent.update(counter, &(&1 + 1))
        Plug.Conn.send_resp(conn, 503, ~s({"status":"overloaded"}))
      end)

      assert {:error, _} =
               Qdrant.search("c", [0.1, 0.2], user_id: Ecto.UUID.generate(), limit: 1)

      assert Agent.get(counter, & &1) == 1
    end
  end
end
