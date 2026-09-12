defmodule Engram.SearchIntegrationTest do
  use Engram.DataCase, async: false

  import Engram.Fixtures, only: [insert_note!: 3]

  @moduletag :qdrant_integration

  setup do
    Engram.Crypto.DekCache.invalidate_all()
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})

    {:ok, vault, _} =
      Engram.Vaults.register_vault(user, "SearchIntegration", Ecto.UUID.generate())

    # Use a test-isolated Qdrant collection so we can drop it after.
    col = "engram_test_#{System.unique_integer([:positive])}"
    old_col = Application.get_env(:engram, :qdrant_collection)
    Application.put_env(:engram, :qdrant_collection, col)

    on_exit(fn ->
      Engram.Vector.Qdrant.delete_collection(col)
      Application.put_env(:engram, :qdrant_collection, old_col)
    end)

    {:ok, user: user, vault: vault, collection: col}
  end

  test "encrypted vault round-trip: upsert → raw payload is ciphertext → search returns plaintext",
       %{user: user, vault: vault, collection: col} do
    note =
      insert_note!(user, vault, %{
        "path" => "Journal/note.md",
        "content" => "# Journal\n\nSensitive body content.",
        "title" => "Journal"
      })

    # `content`/`title` are VIRTUAL fields: the fixture writes ciphertext only,
    # so the struct it returns carries content: nil. Indexing that parses zero
    # chunks and returns {:ok, 0} without ever creating the collection, which
    # surfaced as a confusing 404 two lines down. EmbedNote decrypts first; so
    # must this.
    {:ok, decrypted} = Engram.Crypto.maybe_decrypt_note_fields(note, user)

    assert {:ok, chunk_count} = Engram.Indexing.index_note(decrypted, vault)
    assert chunk_count > 0, "the note must produce chunks, or nothing below is exercised"

    {:ok, info} = Engram.Vector.Qdrant.collection_info(col)
    assert info["points_count"] >= 1

    # Not a hardcoded port: CI runs Qdrant on an ephemeral one (see
    # test_helper.exs), so read the same URL the client uses.
    qdrant_url = Application.get_env(:engram, :qdrant_url, "http://localhost:6333")

    {:ok, resp} =
      Req.post("#{qdrant_url}/collections/#{col}/points/scroll",
        json: %{limit: 10, with_payload: true}
      )

    point = hd(resp.body["result"]["points"])
    payload = point["payload"]

    assert payload["text_nonce"] != nil
    assert payload["text"] != "# Journal"
    assert payload["title"] != "Journal"
    assert payload["vault_id"] == to_string(vault.id)

    {:ok, results} = Engram.Search.search(user, vault, "sensitive body")

    assert results != []

    Enum.each(results, fn r ->
      assert is_binary(r.text)
      refute Map.has_key?(r, :text_nonce)
    end)
  end
end
