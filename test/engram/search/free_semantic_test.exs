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

  test "a Free user's default search embeds the query and runs dense AND keyword legs",
       %{bypass: bypass, user: user, vault: vault} do
    assert Billing.tier(user) == :free

    Engram.MockEmbedder
    |> expect(:embed_texts, fn ["iron panel"], _opts -> {:ok, [List.duplicate(0.1, 3)]} end)

    Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      legs = Enum.map(Jason.decode!(body)["prefetch"], & &1["using"])
      assert Enum.sort(legs) == ["dense", "keyword"]

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": []}))
    end)

    # No `:mode` — the default, and what two MCP call sites send. Hybrid, so
    # a note indexed sparse-only is still reachable.
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

  # MCP's `suggest_folder` and auto-placement call `Search.search/4` with no
  # `:mode`. An over-budget Free user's notes are sparse-only (no dense vector),
  # so a dense-only default finds nothing and reports "No folders found". The
  # default must be hybrid, whose keyword leg still reaches those notes.
  test "an over-budget Free user's suggest_folder still gets folders from BM25",
       %{bypass: bypass, user: user, vault: vault} do
    Engram.UsageMeters.add_embed_tokens(user.id, 20_000_000)

    Engram.MockEmbedder
    |> expect(:embed_texts, fn _texts, _opts -> {:ok, [List.duplicate(0.1, 3)]} end)

    {:ok, enc} =
      Engram.Crypto.encrypt_qdrant_payload(
        %{text: "Ferritin levels.", title: "Iron Panel", heading_path: "Iron Panel"},
        user,
        "engram_notes",
        "uuid-1"
      )

    point = %{
      "id" => "uuid-1",
      "score" => 0.9,
      "payload" => %{
        "text" => enc.text,
        "title" => enc.title,
        "heading_path" => enc.heading_path,
        "text_nonce" => enc.text_nonce,
        "title_nonce" => enc.title_nonce,
        "heading_path_nonce" => enc.heading_path_nonce,
        "aad_version" => enc.aad_version,
        "source_path" => "Health/Iron Panel.md",
        "user_id" => to_string(user.id),
        "vault_id" => to_string(vault.id)
      }
    }

    Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      prefetch = Jason.decode!(body)["prefetch"] || []

      # The sparse note only matches through the keyword leg: a dense-only
      # query reaches nothing, exactly as in production.
      points = if Enum.any?(prefetch, &(&1["using"] == "keyword")), do: [point], else: []

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"result" => %{"points" => points}}))
    end)

    assert {:ok, text, %{"suggestions" => [%{"folder" => "Health"}]}} =
             Engram.MCP.Handlers.handle("suggest_folder", user, vault, %{
               "description" => "iron panel"
             })

    assert text =~ "Health"
  end
end
