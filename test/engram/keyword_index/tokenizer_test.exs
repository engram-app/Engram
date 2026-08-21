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
    # \p{M} is now included in @word_re so combining marks attach to adjacent
    # base letters. For zalgo input the leading orphan combining mark (U+0335
    # before "world") now attaches to "world" giving "\u0335world"; this is
    # harmless adversarial residue — the word is still recoverable and not shattered.
    assert Tokenizer.tokens("ḩ̸̢̛e̵l̶l̷o̴ ̵w̶o̷r̸l̴d̵") == ["ḩello", "̵world"]
  end

  test "does NOT alter precomposed/combining accents, Arabic, Cyrillic, CJK" do
    assert Tokenizer.tokens("café résumé") == ["café", "résumé"]
    assert Tokenizer.tokens("café") == ["café"]
    assert Tokenizer.tokens("مدرسة") == ["مدرسة"]
    # Fully-vowelized Arabic (harakat): \p{M} in @word_re now keeps diacritics
    # attached to their base letters — the whole word stays whole, not shattered.
    assert Tokenizer.tokens("مَدْرَسَةٌ") == ["مَدْرَسَةٌ"]
    # Hebrew with niqqud: same fix — \p{M} keeps the vowel points attached.
    assert Tokenizer.tokens("שָׁלוֹם") == ["שָׁלוֹם"]
    assert Tokenizer.tokens("бегущий") == ["бегущий"]
    assert Tokenizer.tokens("東京都") == ["東京", "京都"]
  end

  # Task 2: dual-emit + English stemming

  test "tokens/2 with nil language is raw-only" do
    assert Tokenizer.tokens("running cats") == ["running", "cats"]
  end

  test "unsupported language atom falls back to raw with no crash" do
    assert Tokenizer.tokens("run", :klingon) == ["run"]
  end

  test "supported non-English language stems correctly" do
    assert Tokenizer.tokens("courir", :fr) == ["courir", "cour"]
  end

  test "Latin tokens dual-emit raw + English stem" do
    assert Tokenizer.tokens("running", :en) == ["running", "run"]
    assert Tokenizer.tokens("cats", :en) == ["cats", "cat"]
  end

  test "token whose stem equals raw is emitted once" do
    assert Tokenizer.tokens("run", :en) == ["run"]
  end

  test "CJK is never stemmed regardless of language" do
    assert Tokenizer.tokens("東京都", :en) == ["東京", "京都"]
  end

  # Task 6: non-Latin script-default stemming (Slice 2a)

  test "non-Latin scripts auto-route to their default Snowball language" do
    # Cyrillic -> :ru
    assert "бегущ" in Tokenizer.tokens("бегущий", :en)
    # Greek -> :el
    assert "τρεχ" in Tokenizer.tokens("τρέχοντας", :en)
    # Arabic -> :ar
    assert "مدرس" in Tokenizer.tokens("مدرسة", :en)
  end

  test "non-Latin scripts dual-emit raw token alongside the stem" do
    assert "бегущий" in Tokenizer.tokens("бегущий", :en)
    assert "τρέχοντας" in Tokenizer.tokens("τρέχοντας", :en)
    assert "مدرسة" in Tokenizer.tokens("مدرسة", :en)
  end

  test "Latin token still uses the passed language, not a script-override" do
    assert "run" in Tokenizer.tokens("running", :en)
    assert "running" in Tokenizer.tokens("running", :en)
  end

  # tokens_with_len/2 — one pass yields both the dual-emit list and the RAW
  # count. `Indexing` used to get the count by tokenizing a second time with
  # language nil, doubling the tokenizer's cost on every indexed chunk.

  describe "tokens_with_len/2" do
    test "raw count excludes stems" do
      assert Tokenizer.tokens_with_len("running cats", :en) ==
               {["running", "run", "cats", "cat"], 2}
    end

    test "raw count agrees with tokens(text, nil) for every language" do
      for text <- [
            "Hello, World!",
            "running cats deploying",
            "東京都",
            "abc東京 def",
            "café résumé",
            "мдрсة бегущий",
            "",
            "set PADDLE_API_KEY now"
          ],
          lang <- [nil, :en, :fr] do
        {_tokens, raw} = Tokenizer.tokens_with_len(text, lang)

        assert raw == length(Tokenizer.tokens(text, nil)),
               "raw count mismatch for #{inspect(text)} / #{inspect(lang)}"
      end
    end

    test "CJK bigrams each count as one raw token" do
      assert Tokenizer.tokens_with_len("東京都", :en) == {["東京", "京都"], 2}
    end

    test "single CJK char counts once" do
      assert Tokenizer.tokens_with_len("猫", :en) == {["猫"], 1}
    end

    test "mixed CJK/Latin run counts each emitted run" do
      {tokens, raw} = Tokenizer.tokens_with_len("abc東京", nil)
      assert tokens == ["abc", "東京"]
      assert raw == 2
    end

    test "non-binary input yields empty list and zero" do
      assert Tokenizer.tokens_with_len(nil, :en) == {[], 0}
    end

    test "tokens/2 stays the token half of tokens_with_len/2" do
      for text <- ["running cats", "東京都", "مدرسة"], lang <- [nil, :en] do
        assert Tokenizer.tokens(text, lang) == elem(Tokenizer.tokens_with_len(text, lang), 0)
      end
    end
  end
end
