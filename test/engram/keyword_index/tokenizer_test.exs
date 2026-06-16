defmodule Engram.KeywordIndex.TokenizerTest do
  use ExUnit.Case, async: true

  alias Engram.KeywordIndex.Tokenizer

  test "lowercases and splits on whitespace/punctuation" do
    assert Tokenizer.tokens("Hello, World!") == ["hello", "world"]
  end

  test "keeps identifiers whole (underscore in-token)" do
    assert Tokenizer.tokens("set PADDLE_API_KEY now") == ["set", "paddle_api_key", "now"]
  end

  test "NFKC-normalizes accented text" do
    assert Tokenizer.tokens("Café") == ["café"]
  end

  test "emits overlapping bigrams for CJK runs" do
    assert Tokenizer.tokens("東京都") == ["東京", "京都"]
  end

  test "single CJK char yields itself" do
    assert Tokenizer.tokens("猫") == ["猫"]
  end

  test "non-binary input yields empty list" do
    assert Tokenizer.tokens(nil) == []
  end
end
