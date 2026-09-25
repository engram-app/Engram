defmodule Engram.Search.FreeSemanticTest do
  # Semantic search is every tier's, Free included. The old
  # `search_semantic_enabled` key forced Free to `:keyword`; it no longer
  # exists, and override rows left over under that key must stay inert.
  use Engram.DataCase, async: false

  import Mox

  alias Engram.Billing
  alias Engram.Search
  alias Engram.Search.SearchProfile

  setup :verify_on_exit!

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    {:ok, user} = insert(:user) |> Engram.Crypto.ensure_user_dek()
    vault = insert(:vault, user: user)
    %{bypass: bypass, user: user, vault: vault}
  end

  defp expect_dense_search(bypass) do
    Engram.MockEmbedder
    |> expect(:embed_texts, fn ["iron panel"], _opts -> {:ok, [List.duplicate(0.1, 3)]} end)

    Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": []}))
    end)
  end

  test "a Free user's search embeds the query and runs the dense leg",
       %{bypass: bypass, user: user, vault: vault} do
    assert Billing.tier(user) == :free
    expect_dense_search(bypass)

    # No `:mode` — the default, and what two MCP call sites send.
    assert {:ok, []} = Search.search(user, vault, "iron panel", diversity: 0.0)
  end

  test "a Free user can still ask for keyword-only search", %{
    bypass: bypass,
    user: user,
    vault: vault
  } do
    # No embedder expectation: :keyword must not embed the query.
    Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": []}))
    end)

    assert {:ok, []} = Search.search(user, vault, "iron panel", mode: :keyword, diversity: 0.0)
  end

  test "a stale search_semantic_enabled override row is inert",
       %{bypass: bypass, user: user, vault: vault} do
    # Written before the key was removed. `Repo.insert!` on the struct skips the
    # changeset, which now rejects the key, exactly like a row already in prod.
    Engram.Repo.insert!(%Engram.Billing.UserLimitOverride{
      user_id: user.id,
      key: "search_semantic_enabled",
      value: %{"v" => false},
      reason: "stale row from before the key was removed",
      set_by: "test"
    })

    Engram.Billing.OverrideCache.evict(user.id)

    assert %SearchProfile{} = SearchProfile.resolve(user)
    caps = Billing.capabilities(user)
    refute Map.has_key?(caps, :search_semantic_enabled)
    refute Map.has_key?(caps, "search_semantic_enabled")

    # `false` in the stale row must not switch the dense leg off.
    expect_dense_search(bypass)
    assert {:ok, []} = Search.search(user, vault, "iron panel", mode: :hybrid, diversity: 0.0)
  end
end
