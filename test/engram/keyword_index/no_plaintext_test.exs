defmodule Engram.KeywordIndex.NoPlaintextTest do
  use Engram.DataCase, async: true

  alias Engram.Crypto
  alias Engram.KeywordIndex.QdrantSparse

  test "the stored sparse vector contains no plaintext tokens and is unkeyed-irreversible" do
    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    {:ok, key} = Crypto.dek_filter_key(user)

    text = "PADDLE_API_KEY secret rotation paddle"
    %{indices: indices, values: values} = QdrantSparse.encode_document(text, key, 4, 4.0)

    # Only integers and floats are emitted — no token strings.
    assert Enum.all?(indices, &is_integer/1)
    assert Enum.all?(values, &is_float/1)

    # None of the source tokens appear verbatim as a dimension.
    for token <- ["paddle_api_key", "secret", "rotation", "paddle"] do
      refute token in Enum.map(indices, &to_string/1)
    end

    # Non-reversibility: a different key produces different dims for the same
    # token — so the dims are not a public hash of the plaintext.
    {:ok, other_user} = Crypto.ensure_user_dek(insert(:user))
    {:ok, other_key} = Crypto.dek_filter_key(other_user)
    refute QdrantSparse.dim(key, "secret") == QdrantSparse.dim(other_key, "secret")
  end

  test "stems produced by dual-emit are HMAC'd — no plaintext stem stored" do
    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    {:ok, key} = Crypto.dek_filter_key(user)

    # With :en language the tokenizer dual-emits raw + stem for each word
    # where they differ: "running"→"run", "deploying"→"deploy", "changes"→"chang".
    text = "running deploying changes"
    %{indices: indices, values: values} = QdrantSparse.encode_document(text, key, 3, 4.0, :en)

    # Only HMAC u32 integers and BM25 floats — no plaintext strings.
    assert Enum.all?(indices, &is_integer/1)
    assert Enum.all?(values, &is_float/1)

    # None of the raw tokens or expected stems appear verbatim as a dimension.
    plaintext_tokens = ["running", "deploying", "changes", "run", "deploy", "chang"]

    for token <- plaintext_tokens do
      refute token in Enum.map(indices, &to_string/1)
    end

    # Stemming actually ran: the stem dimensions ARE present in the encoded output.
    # This locks the dual-emit path against future regressions that silently skip stems.
    for stem <- ["run", "deploy", "chang"] do
      assert QdrantSparse.dim(key, stem) in indices,
             "expected stem #{inspect(stem)} to be HMAC'd and present in indices"
    end
  end
end
