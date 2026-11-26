defmodule Engram.SearchKeywordStoreEquivalenceTest do
  @moduledoc """
  Search through the keyword store seam (`Engram.KeywordStore`, P1) is
  byte-for-byte what it was before: the same Qdrant requests and the same
  results on a fixed fixture, for the keyword-only, hybrid and degraded
  (embed failed) paths. Written against main before the seam, unchanged
  after it.
  """
  use Engram.DataCase, async: true

  import Mox
  import Engram.Fixtures, only: [insert_chunk!: 4, insert_note!: 3]

  alias Engram.QdrantStub
  alias Engram.Search
  alias Engram.ServiceConfig

  setup :verify_on_exit!

  # The tenant filter both legs carry (either payload spelling of user and vault).
  @filter %{
    "must" => [
      %{
        "should" => [
          %{"key" => "user_id", "match" => %{"value" => "USER"}},
          %{"key" => "u", "match" => %{"value" => "USER"}}
        ]
      },
      %{
        "should" => [
          %{"key" => "vault_id", "match" => %{"value" => "VAULT"}},
          %{"key" => "v", "match" => %{"value" => "VAULT"}}
        ]
      }
    ]
  }

  @ids for d <- ~w(1 5 9), do: String.duplicate(d, 8) <> "-0000-4000-8000-000000000000"

  setup do
    bypass = Bypass.open()
    QdrantStub.stub_retrieve(bypass)
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    ServiceConfig.put_override(:qdrant_search_timeout, 30_000)
    {:ok, user} = insert(:user) |> Engram.Crypto.ensure_user_dek()
    vault = insert(:vault, user: user)

    [a, m, z] =
      for {id, name} <- Enum.zip(@ids, ~w(alpha mid zulu)) do
        note = insert_note!(user, vault, %{path: "#{name}.md", title: name})
        insert_chunk!(user, note, id, text: "ferritin #{name}")
        id
      end

    %{bypass: bypass, user: user, vault: vault, ids: {a, m, z}}
  end

  # Replace the per-test values (DEK-keyed sparse dims, tenant ids) so the
  # body compares to a literal.
  defp normalize(body, user, vault) do
    body
    |> Jason.encode!()
    |> String.replace(Engram.Vector.FilterId.uuid(to_string(user.id)), "USER")
    |> String.replace(Engram.Vector.FilterId.uuid(to_string(vault.id)), "VAULT")
    |> String.replace(to_string(user.id), "USER")
    |> String.replace(to_string(vault.id), "VAULT")
    |> Jason.decode!()
    |> scrub_sparse()
  end

  defp scrub_sparse(%{"indices" => i, "values" => v}) when is_list(i),
    do: %{"indices" => length(i), "values" => length(v)}

  defp scrub_sparse(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, scrub_sparse(v)} end)
  defp scrub_sparse(list) when is_list(list), do: Enum.map(list, &scrub_sparse/1)
  defp scrub_sparse(other), do: other

  defp reply(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  defp capture(bypass, path, respond) do
    test_pid = self()

    Bypass.expect_once(bypass, "POST", "/collections/engram_notes" <> path, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:body, Jason.decode!(body)})
      reply(conn, respond.(conn))
    end)
  end

  defp summary(results), do: Enum.map(results, &{&1.title, &1.text, Float.round(&1.score, 6)})

  test "keyword-only", %{bypass: bypass, user: user, vault: vault, ids: {a, m, z}} do
    capture(bypass, "/points/query", fn _conn ->
      %{"result" => %{"points" => [%{"id" => z, "score" => 3.0}, %{"id" => a, "score" => 2.0}]}}
    end)

    assert {:ok, results} = Search.search(user, vault, "ferritin", mode: :keyword, diversity: 0)
    assert summary(results) == [{"zulu", "ferritin zulu", 3.0}, {"alpha", "ferritin alpha", 2.0}]
    refute Enum.any?(results, &(&1.qdrant_id == m))

    assert_received {:body, body}

    assert normalize(body, user, vault) == %{
             "filter" => @filter,
             "limit" => 5,
             "query" => %{"indices" => 1, "values" => 1},
             "using" => "keyword",
             "with_payload" => false
           }
  end

  test "hybrid", %{bypass: bypass, user: user, vault: vault, ids: {a, m, z}} do
    expect(Engram.MockEmbedder, :embed_texts, fn ["ferritin"], _opts ->
      {:ok, [[0.1, 0.2, 0.3]]}
    end)

    capture(bypass, "/points/query/batch", fn conn ->
      dense = %{"result" => [%{"id" => m, "score" => 0.9}, %{"id" => a, "score" => 0.8}]}
      QdrantStub.batch(conn, dense, [%{"id" => m, "score" => 12.0}, %{"id" => z, "score" => 9.0}])
    end)

    assert {:ok, results} = Search.search(user, vault, "ferritin", mode: :hybrid, diversity: 0)

    assert summary(results) == [
             {"mid", "ferritin mid", Float.round(QdrantStub.rrf(0) * 2, 6)},
             {"alpha", "ferritin alpha", Float.round(QdrantStub.rrf(1), 6)},
             {"zulu", "ferritin zulu", Float.round(QdrantStub.rrf(1), 6)}
           ]

    assert_received {:body, body}
    filter = @filter

    assert %{"searches" => [dense_leg, keyword_leg]} = normalize(body, user, vault)

    assert dense_leg == %{
             "filter" => filter,
             "limit" => 5,
             "params" => %{"quantization" => %{"oversampling" => 3.0, "rescore" => true}},
             "query" => [0.1, 0.2, 0.3],
             "using" => "dense",
             "with_payload" => false
           }

    assert keyword_leg == %{
             "filter" => filter,
             "limit" => 5,
             "query" => %{"indices" => 1, "values" => 1},
             "using" => "keyword",
             "with_payload" => false
           }
  end

  test "degraded to keyword-only when the query embed fails",
       %{bypass: bypass, user: user, vault: vault, ids: {a, _m, _z}} do
    expect(Engram.MockEmbedder, :embed_texts, fn _texts, _opts -> {:error, :timeout} end)

    capture(bypass, "/points/query", fn _conn ->
      %{"result" => %{"points" => [%{"id" => a, "score" => 2.0}]}}
    end)

    ExUnit.CaptureLog.capture_log(fn ->
      assert {:ok, results} = Search.search(user, vault, "ferritin", mode: :hybrid, diversity: 0)
      send(self(), {:results, results})
    end)

    assert_received {:results, results}
    assert summary(results) == [{"alpha", "ferritin alpha", 2.0}]
    assert_received {:body, %{"using" => "keyword"}}
  end
end
