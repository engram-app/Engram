defmodule Engram.SearchIntegrationTest do
  use Engram.DataCase, async: false

  @moduletag :qdrant_integration

  import Engram.Fixtures, only: [insert_note!: 3]

  setup do
    Engram.Crypto.DekCache.invalidate_all()
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    insert(:user_override, user: user, overrides: %{"max_vaults" => -1})
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "SearchIntegration"})

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

    {:ok, _n} = Engram.Indexing.index_note(note, vault)

    {:ok, info} = Engram.Vector.Qdrant.collection_info(col)
    assert info["points_count"] >= 1

    {:ok, resp} =
      Req.post("http://localhost:6333/collections/#{col}/points/scroll",
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
