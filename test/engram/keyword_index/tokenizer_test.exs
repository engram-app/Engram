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

  test "strips Turkish dotted-I casefold artifact (no word split)" do
    assert Tokenizer.tokens("İstanbul") == ["istanbul"]
  end

  test "de-shatters zalgo combining-mark spam" do
    # Leading ḩ survives: its cedilla (U+0327) is attached to a precomposed
    # base glyph, so after NFKC the Mn mark is gone; the remaining combining
    # marks on 'e'/'l'/etc. are stripped by the Latin-scoped lookbehind, but
    # ḩ itself is already a single composed grapheme with no trailing Mn.
    assert Tokenizer.tokens("ḩ̸̢̛e̵l̶l̷o̴ ̵w̶o̷r̸l̴d̵") == ["ḩello", "world"]
  end

  test "does NOT alter precomposed/combining accents, Arabic, Cyrillic, CJK" do
    assert Tokenizer.tokens("café résumé") == ["café", "résumé"]
    assert Tokenizer.tokens("café") == ["café"]
    assert Tokenizer.tokens("مدرسة") == ["مدرسة"]
    # Fully-vowelized Arabic (harakat are \p{Mn} on a non-Latin base): the
    # Latin-scoped lookbehind guard does NOT strip them (Arabic base, not Latin).
    # The word regex [\p{L}\p{N}_]+ then naturally splits on the \p{Mn} marks,
    # yielding individual letters — the base letters are intact, none are lost.
    assert Tokenizer.tokens("مَدْرَسَةٌ") == ["م", "د", "ر", "س", "ة"]
    assert Tokenizer.tokens("бегущий") == ["бегущий"]
    assert Tokenizer.tokens("東京都") == ["東京", "京都"]
  end
end
