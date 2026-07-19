defmodule Engram.Embedders.OllamaTest do
  use ExUnit.Case, async: true

  alias Engram.Embedders.Ollama

  # Stub the HTTP layer via Req's `plug:` adapter (routed through embed_texts
  # opts) so these run async with no network and no OLLAMA_URL env mutation.
  defp json_resp(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  describe "embed_texts/2" do
    test "returns vectors on success" do
      plug = fn conn -> json_resp(conn, 200, %{"embeddings" => [[0.1, 0.2], [0.3, 0.4]]}) end
      assert {:ok, [[0.1, 0.2], [0.3, 0.4]]} = Ollama.embed_texts(["a", "b"], plug: plug)
    end

    test "retries a transient 5xx and succeeds (Oban embeds must survive a blip to remote Ollama)" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      plug = fn conn ->
        n = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
        # First call: transient 503 (a FastRaid Ollama blip). Retry succeeds.
        if n == 1,
          do: json_resp(conn, 503, %{"error" => "loading"}),
          else: json_resp(conn, 200, %{"embeddings" => [[1.0, 2.0]]})
      end

      # retry_delay 0 keeps the test instant; retry: :transient is the fix.
      assert {:ok, [[1.0, 2.0]]} =
               Ollama.embed_texts(["hi"], plug: plug, retry_delay: fn _ -> 0 end)

      assert Agent.get(counter, & &1) == 2
    end

    test "gives up after max_retries on a persistent failure" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      plug = fn conn ->
        Agent.update(counter, &(&1 + 1))
        json_resp(conn, 503, %{"error" => "down"})
      end

      assert {:error, {503, _}} =
               Ollama.embed_texts(["hi"], plug: plug, retry_delay: fn _ -> 0 end)

      # 1 initial + 3 retries (max_retries: 3).
      assert Agent.get(counter, & &1) == 4
    end
  end

  describe "retry_fast_transient?/2" do
    test "retries fast failures but NOT a receive_timeout (no 120s amplification)" do
      # A hang-to-timeout must not be retried, else max_retries multiplies the
      # 120s receive_timeout into a multi-minute stall.
      refute Ollama.retry_fast_transient?(nil, %Req.TransportError{reason: :timeout})
      # Connection-level blips and 5xx fail fast → cheap to retry.
      assert Ollama.retry_fast_transient?(nil, %Req.TransportError{reason: :econnrefused})
      assert Ollama.retry_fast_transient?(nil, %Req.Response{status: 503})
      # 4xx / success are not transient.
      refute Ollama.retry_fast_transient?(nil, %Req.Response{status: 422})
      refute Ollama.retry_fast_transient?(nil, %Req.Response{status: 200})
    end
  end
end
