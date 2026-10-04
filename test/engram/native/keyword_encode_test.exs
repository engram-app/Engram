defmodule Engram.Native.KeywordEncodeTest do
  # async: false — the leak test reads a process-wide counter.
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Engram.KeywordIndex.{NativeSparse, QdrantSparse}

  @key :crypto.strong_rand_bytes(32)

  # Qdrant sorts a sparse vector's indices on upsert, so ORDER is not part of
  # the contract; the dim -> value map and doc_len are.
  defp canonical(encoded) do
    for {packed, len} <- encoded do
      %{indices: i, values: v} = QdrantSparse.unpack(packed)
      {Map.new(Enum.zip(i, v)), len}
    end
  end

  defp assert_same(texts, lang) do
    assert canonical(NativeSparse.encode_documents(texts, @key, 7.5, lang)) ==
             canonical(QdrantSparse.encode_documents(texts, @key, 7.5, lang))
  end

  setup_all do
    _ = start_supervised(Engram.KeywordIndex.StemCache)
    :ok
  end

  describe "differential: the Rust encoder is the Elixir encoder" do
    # Each of these broke an earlier draft of the port, or is a documented
    # Tokenizer special case.
    test "known edge cases" do
      texts = [
        "",
        "ΣΑΣ σας Σ",
        "İstanbul ﬁle naïve é́",
        "東京タワー 한국어 ひらがな",
        "running ran runs — curly ‘quotes’",
        "x_y snake_case 0.75 ١٢٣ २०२६",
        "Жизнь ζωή حياة",
        String.duplicate("a", 5_000)
      ]

      for lang <- [nil, :en, :de, :ru, :fr, :en_porter, :tr] do
        assert_same(texts, lang)
      end
    end

    property "random Unicode text, every stemmer language" do
      pool =
        ~c"aZ9_ -.,İıﬁé̈ñßΣσςЖжΩαάبِשָׁ東京한국ひらカタ0١२😀́̇ ‍\t\n"
        |> to_string()
        |> String.graphemes()

      # Not `string(:printable)`: arbitrary codepoints DO diverge, on purpose.
      # The Elixir tokenizer classified characters with OTP's PCRE 8.45 tables
      # (2021); Rust uses current Unicode. They disagree on ~39k codepoints,
      # nearly all unassigned in 2021 or in rare scripts. Real text across the
      # scripts in `pool` must still match exactly.
      check all(
              chunks <-
                list_of(map(list_of(member_of(pool), max_length: 60), &Enum.join/1),
                  max_length: 8
                ),
              lang <- member_of([nil | Text.Stemmer.supported_languages()]),
              max_runs: 300
            ) do
        assert_same(chunks, lang)
      end
    end
  end

  property "queries encode the same as the Elixir encoder" do
    words = ~w(running fast İstanbul ﬁle ΣΑΣ 東京タワー x_y naïve)

    check all(
            picked <- list_of(member_of(words), max_length: 6),
            lang <- member_of([nil, :en, :de, :tr])
          ) do
      q = Enum.join(picked, " ")
      native = NativeSparse.encode_query(q, @key, lang)
      elixir = QdrantSparse.encode_query(q, @key, lang)

      assert Map.new(Enum.zip(native.indices, native.values)) ==
               Map.new(Enum.zip(elixir.indices, elixir.values))
    end
  end

  describe "memory standard" do
    test "native peak stays within 4x the input, even for one huge token" do
      for texts <- [
            [String.duplicate("a", 2_000_000)],
            for(i <- 1..2_000, do: "chunk #{i} " <> String.duplicate("word#{i} ", 100))
          ] do
        {_, peak} = Engram.Native.encode_documents_nif(texts, @key, 300.0, "en")
        assert peak <= 4 * :erlang.iolist_size(texts) + 65_536
      end
    end

    test "repeated calls leak nothing" do
      texts = for i <- 1..20, do: "note #{i} running fast and far"
      # Warm-up: lazily compiled regexes live for the life of the library.
      Engram.Native.encode_documents_nif(texts, @key, 300.0, "en")
      before = Engram.Native.live_bytes()
      for _ <- 1..300, do: Engram.Native.encode_documents_nif(texts, @key, 300.0, "en")
      assert Engram.Native.live_bytes() - before == 0
    end

    test "every call emits [:engram, :nif, :call, :stop]" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :nif, :call, :stop]])
      Engram.Native.encode_documents(["hello world"], @key, 3.0, nil)

      assert_receive {[:engram, :nif, :call, :stop], ^ref,
                      %{duration: d, native_peak_bytes: p, input_bytes: 11},
                      %{nif: :keyword_encode}}

      assert d > 0 and p > 0
    end

    test "memory_snapshot sets RSS against what the BEAM accounts for" do
      snap = Engram.Native.memory_snapshot()
      assert snap.rss > snap.erlang_total
      assert snap.unaccounted == snap.rss - snap.erlang_total
      assert is_integer(snap.nif_live)
    end
  end
end
