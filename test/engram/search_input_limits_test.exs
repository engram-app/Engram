defmodule Engram.SearchInputLimitsTest do
  @moduledoc """
  Search refuses an input Qdrant Cloud's strict limits or Voyage's context
  window would refuse later, before it is billed or sent anywhere.
  """
  use Engram.DataCase, async: false

  import Mox

  alias Engram.Search
  alias Engram.Vector.Qdrant

  setup :verify_on_exit!

  setup do
    # Nothing may reach Qdrant: a request here fails the test.
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    {:ok, user} = insert(:user) |> Engram.Crypto.ensure_user_dek()
    %{user: user, vault: insert(:vault, user: user)}
  end

  test "more tags than one match-any condition holds is refused", %{user: user, vault: vault} do
    tags = for i <- 1..(Qdrant.max_ids() + 1), do: "t#{i}"
    assert Search.search(user, vault, "iron", tags: tags) == {:error, :too_many_tags}
  end

  test "no tags, an empty list and exactly max_ids tags pass" do
    assert Search.validate_input("iron", []) == :ok
    assert Search.validate_input("iron", tags: []) == :ok
    assert Search.validate_input("iron", tags: for(i <- 1..Qdrant.max_ids(), do: "t#{i}")) == :ok
  end

  # A query past Voyage's context window used to lose its dense leg (with
  # `truncation: false` the embed 400s and search degrades to keyword-only).
  # Refused at the boundary instead, before billing, with no embed call (the
  # Mox embedder has no expectation, so a call fails the test).
  test "a query over max_query_bytes is refused, unbilled and unembedded",
       %{user: user, vault: vault} do
    long = String.duplicate("a", Search.max_query_bytes() + 1)
    assert Search.search(user, vault, long) == {:error, :query_too_long}
    assert Search.validate_input(String.duplicate("a", Search.max_query_bytes()), []) == :ok
  end

  test "multi-byte text is measured in bytes" do
    char = "é"
    over = String.duplicate(char, div(Search.max_query_bytes(), 2) + 1)
    assert Search.validate_input(over, []) == {:error, :query_too_long}
  end

  test "both refusals carry a caller-facing message" do
    assert Search.input_error_message(:query_too_long) =~ "bytes"
    assert Search.input_error_message(:too_many_tags) =~ "tags"
    assert Search.input_error_message(:other) == nil
  end
end
