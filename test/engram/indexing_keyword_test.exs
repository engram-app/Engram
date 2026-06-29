defmodule Engram.IndexingKeywordTest do
  use Engram.DataCase, async: true

  import Mox

  alias Engram.Crypto
  alias Engram.Indexing
  alias Engram.KeywordIndex.QdrantSparse
  alias Engram.Notes
  alias Engram.ServiceConfig

  setup :verify_on_exit!

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)

    {:ok, note} =
      Notes.upsert_note(user, vault, %{
        "path" => "n.md",
        "content" => "alpha beta gamma",
        "mtime" => 1_000.0
      })

    {:ok, note} = Crypto.maybe_decrypt_note_fields(note, user)

    %{bypass: bypass, user: user, vault: vault, note: note}
  end

  test "slice-1 stemming: inflected English term produces stem dim and raw token_count", %{
    bypass: bypass,
    user: user,
    vault: vault
  } do
    # Note content contains an inflected form; expect the stem dim to appear.
    chunk_text = "deploying containers"

    {:ok, note} =
      Notes.upsert_note(user, vault, %{
        "path" => "stem_test.md",
        "content" => chunk_text,
        "mtime" => 2_000.0
      })

    {:ok, note} = Crypto.maybe_decrypt_note_fields(note, user)

    Engram.MockEmbedder
    |> expect(:embed_texts, fn texts ->
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    Bypass.expect(bypass, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true}))
    end)

    {:ok, prepared} = Indexing.prepare_index(note, vault)
    [point | _] = prepared.qdrant_points
    %{"keyword" => %{indices: indices}} = point.vector

    {:ok, key} = Crypto.dek_filter_key(user)

    # "deploying" must produce the "deploy" stem dim (Slice-1 English dual-emit)
    assert QdrantSparse.dim(key, "deploy") in indices

    # token_count = RAW token count (language nil), not dual-emit count
    alias Engram.KeywordIndex.Tokenizer
    expected_raw = chunk_text |> Tokenizer.tokens(nil) |> length()
    assert hd(prepared.chunk_rows).token_count == expected_raw
  end

  test "each qdrant point carries a named dense + keyword sparse vector", %{
    bypass: bypass,
    user: user,
    note: note,
    vault: vault
  } do
    Engram.MockEmbedder
    |> expect(:embed_texts, fn texts ->
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    Bypass.expect(bypass, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true}))
    end)

    {:ok, prepared} = Indexing.prepare_index(note, vault)
    [point | _] = prepared.qdrant_points

    assert %{"dense" => dense, "keyword" => %{indices: indices, values: values}} = point.vector
    assert is_list(dense)
    assert length(indices) == length(values)
    assert indices != []

    {:ok, key} = Crypto.dek_filter_key(user)
    assert QdrantSparse.dim(key, "alpha") in indices
    refute Enum.any?(indices, &(&1 == "alpha"))

    assert hd(prepared.chunk_rows).token_count == 3
  end
end
