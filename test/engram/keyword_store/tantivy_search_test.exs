defmodule Engram.KeywordStore.TantivySearchTest do
  @moduledoc """
  Search through `Engram.KeywordStore.Tantivy`: the keyword leg goes to a
  stub kwsearch (Bypass), the dense leg to a stub vector service, in
  parallel, fused by point id. Pins the request kwsearch gets (tenant in the
  signed token only, compact id lists) and the keyword-down fallback.
  """
  use Engram.DataCase, async: true

  import Mox
  import Engram.Fixtures, only: [insert_chunk!: 4, insert_note!: 3]

  alias Engram.KeywordStore.Tantivy
  alias Engram.KeywordStore.Tantivy.Token
  alias Engram.QdrantStub
  alias Engram.Search
  alias Engram.ServiceConfig

  setup :verify_on_exit!

  @key "test-token-key-0123456789abcdef01234567"
  @ids for d <- ~w(1 5 9), do: String.duplicate(d, 8) <> "-0000-4000-8000-000000000000"

  setup do
    dense = Bypass.open()
    kw = Bypass.open()
    QdrantStub.stub_retrieve(dense)
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{dense.port}")
    ServiceConfig.put_override(:qdrant_search_timeout, 30_000)
    ServiceConfig.put_override(:keyword_feed, true)
    ServiceConfig.put_override(:keyword_read, :tantivy)

    ServiceConfig.put_override(:kwsearch,
      url: "http://localhost:#{kw.port}",
      allow_http: true,
      token_keys: [@key],
      timeout_ms: 5_000
    )

    {:ok, user} = insert(:user) |> Engram.Crypto.ensure_user_dek()
    vault = insert(:vault, user: user)

    [a, m, z] =
      for {id, name} <- Enum.zip(@ids, ~w(alpha mid zulu)) do
        note = insert_note!(user, vault, %{path: "#{name}.md", title: name})
        insert_chunk!(user, note, id, text: "ferritin #{name}")
        id
      end

    %{dense: dense, kw: kw, user: user, vault: vault, ids: {a, m, z}}
  end

  defp reply(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp kwsearch(kw, status, body) do
    test_pid = self()

    Bypass.expect_once(kw, "POST", "/search", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      ["Bearer " <> token] = Plug.Conn.get_req_header(conn, "authorization")
      send(test_pid, {:kwsearch, token, Jason.decode!(raw)})
      reply(conn, status, body)
    end)
  end

  defp dense_leg(dense, hits) do
    Bypass.expect_once(dense, "POST", "/collections/engram_notes/points/query", fn conn ->
      reply(conn, 200, %{"result" => %{"points" => hits}})
    end)
  end

  defp summary(results), do: Enum.map(results, &{&1.title, Float.round(&1.score, 6)})

  defp embed_ok,
    do: expect(Engram.MockEmbedder, :embed_texts, fn ["ferritin"], _ -> {:ok, [[0.1, 0.2]]} end)

  test "hybrid fuses the dense leg and the kwsearch leg by point id",
       %{dense: dense, kw: kw, user: user, vault: vault, ids: {a, m, z}} do
    embed_ok()
    dense_leg(dense, [%{"id" => m, "score" => 0.9}, %{"id" => a, "score" => 0.8}])
    kwsearch(kw, 200, %{"hits" => [[m, 12.0], [z, 9.0]]})

    assert {:ok, results} = Search.search(user, vault, "ferritin", mode: :hybrid, diversity: 0)

    assert summary(results) == [
             {"mid", Float.round(QdrantStub.rrf(0) * 2, 6)},
             {"alpha", Float.round(QdrantStub.rrf(1), 6)},
             {"zulu", Float.round(QdrantStub.rrf(1), 6)}
           ]

    # The tenant is in the signed token only, never in the body.
    assert_received {:kwsearch, token, body}

    assert {:ok, %{"s" => "search", "u" => u, "v" => [v]}} = Token.verify(token, [@key])
    assert u == to_string(user.id) and v == to_string(vault.id)
    assert Map.keys(body) |> Enum.sort() == ~w(gen limit terms)
    refute Map.has_key?(body, "user")
  end

  # Review #2: with the default diversity the fused ids are retrieved for
  # their dense vectors, and a keyword hit the vector service did not return
  # used to vanish there.
  test "default diversity: a hit only the keyword leg found is kept",
       %{dense: dense, kw: kw, user: user, vault: vault, ids: {_a, _m, z}} do
    embed_ok()
    dense_leg(dense, [])
    kwsearch(kw, 200, %{"hits" => [[z, 9.0]]})

    assert {:ok, [%{title: "zulu"}]} = Search.search(user, vault, "ferritin", mode: :hybrid)
  end

  # Review #5: an all-vaults search names the user's vaults in the token.
  test "no vault scope: the token carries the user's active vaults, never []",
       %{kw: kw, user: user, vault: vault} do
    kwsearch(kw, 200, %{"hits" => []})

    assert {:ok, []} =
             Tantivy.search(%{indices: [1], values: [1.0]}, user_id: to_string(user.id), limit: 5)

    assert_received {:kwsearch, token, _body}
    assert {:ok, %{"v" => [v]}} = Token.verify(token, [@key])
    assert v == to_string(vault.id)
  end

  test "a user with no active vault calls nothing and counts no fallback" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :search, :keyword_fallback]])
    lonely = insert(:user)

    assert {:ok, []} =
             Tantivy.search(%{indices: [1], values: [1.0]},
               user_id: to_string(lonely.id),
               limit: 5
             )

    refute_received {[:engram, :search, :keyword_fallback], ^ref, _, _}
  end

  test "kwsearch down: hybrid is dense-only and counts a fallback",
       %{dense: dense, kw: kw, user: user, vault: vault, ids: {a, m, _z}} do
    embed_ok()
    dense_leg(dense, [%{"id" => m, "score" => 0.9}, %{"id" => a, "score" => 0.8}])
    kwsearch(kw, 503, %{"error" => "not_ready"})
    ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :search, :keyword_fallback]])

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:ok, results} =
               Search.search(user, vault, "ferritin", mode: :hybrid, diversity: 0)

      send(self(), {:results, results})
    end)

    assert_received {:results, results}
    assert Enum.map(results, & &1.title) == ["mid", "alpha"]

    assert_received {[:engram, :search, :keyword_fallback], ^ref, %{count: 1},
                     %{outcome: :dense_only, reason: "status_503"}}
  end

  test "kwsearch unreachable: hybrid still answers from the dense leg",
       %{dense: dense, kw: kw, user: user, vault: vault, ids: {a, _m, _z}} do
    embed_ok()
    dense_leg(dense, [%{"id" => a, "score" => 0.8}])
    Bypass.down(kw)

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:ok, results} =
               Search.search(user, vault, "ferritin", mode: :hybrid, diversity: 0)

      send(self(), {:results, results})
    end)

    assert_received {:results, [%{title: "alpha"}]}
  end

  test "keyword mode returns an explicit degraded error, not an empty list",
       %{kw: kw, user: user, vault: vault} do
    kwsearch(kw, 500, %{"error" => "internal"})

    ExUnit.CaptureLog.capture_log(fn ->
      send(self(), {:r, Search.search(user, vault, "ferritin", mode: :keyword, diversity: 0)})
    end)

    assert_received {:r, {:error, :keyword_degraded}}
  end

  test "note id lists go as base64 of the raw 16-byte ids", %{kw: kw} do
    kwsearch(kw, 200, %{"hits" => []})
    ids = Enum.take(@ids, 2)

    assert {:ok, []} =
             Tantivy.search(%{indices: [7, 9], values: [1.0, 1.0]},
               user_id: Ecto.UUID.generate(),
               vault_id: [Ecto.UUID.generate()],
               note_scope: {:exclude, ids},
               limit: 40
             )

    assert_received {:kwsearch, _token, body}
    assert body["terms"] == [7, 9] and body["limit"] == 40
    assert Base.decode64!(body["exclude_b64"]) == Enum.map_join(ids, &Ecto.UUID.dump!/1)
  end

  test "a plain-HTTP kwsearch URL is refused unless allowed (security F6)" do
    ServiceConfig.put_override(:kwsearch,
      url: "http://kwsearch.internal:7700",
      token_keys: [@key]
    )

    ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :search, :keyword_fallback]])

    ExUnit.CaptureLog.capture_log(fn ->
      send(
        self(),
        {:r,
         Tantivy.search(%{indices: [1], values: [1.0]},
           user_id: Ecto.UUID.generate(),
           vault_id: Ecto.UUID.generate()
         )}
      )
    end)

    assert_received {:r, {:error, :keyword_degraded}}

    assert_received {[:engram, :search, :keyword_fallback], ^ref, _,
                     %{reason: ":kwsearch_plain_http"}}
  end
end
