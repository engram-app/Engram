defmodule Engram.Native.HmacHexManyTest do
  # async: false — the leak test reads a process-wide counter.
  use ExUnit.Case, async: false

  alias Engram.Crypto
  alias Engram.Native

  @key :crypto.strong_rand_bytes(32)

  # Stored `chunks.context_hmac` values were written by the Elixir form. Any
  # drift re-fingerprints every chunk in prod as "changed": a full re-embed,
  # billed. Parity is the whole contract.
  test "matches Crypto.hmac_content_hash/2 over prefix <> text" do
    texts = ["", "a", "ünïcödé 東京 🙂", String.duplicate("x", 5_000), <<0, 255, 10>>]

    for prefix <- ["dense:voyage-4-large\n", "sparse\n", ""] do
      assert Native.hmac_hex_many(@key, prefix, texts) ==
               Enum.map(texts, &Crypto.hmac_content_hash(@key, prefix <> &1))
    end
  end

  test "the dirty path (over 16 KB) gives the same answers" do
    texts = for i <- 1..20, do: String.duplicate("chunk #{i} ", 200)
    assert :erlang.iolist_size(texts) > 16_384

    assert Native.hmac_hex_many(@key, "sparse\n", texts) ==
             Enum.map(texts, &Crypto.hmac_content_hash(@key, "sparse\n" <> &1))
  end

  test "an empty batch and a wrong-size key" do
    assert Native.hmac_hex_many(@key, "sparse\n", []) == []
    assert_raise FunctionClauseError, fn -> Native.hmac_hex_many(<<1, 2>>, "x", ["a"]) end
  end

  describe "memory standard" do
    # Hex outputs are BEAM binaries, not Rust heap; the native side holds only
    # the output list and the HMAC state.
    test "native peak is bounded by the batch size, not the text size" do
      texts = for i <- 1..2_000, do: String.duplicate("w#{i} ", 400)
      {_, peak} = Native.hmac_hex_many_dirty_nif(@key, "sparse\n", texts)
      assert peak <= 64 * 2_000 + 65_536
    end

    test "repeated calls leak nothing" do
      texts = for i <- 1..20, do: "chunk #{i}"
      Native.hmac_hex_many_nif(@key, "p", texts)
      before = Native.live_bytes()
      for _ <- 1..300, do: Native.hmac_hex_many_nif(@key, "p", texts)
      assert Native.live_bytes() - before == 0
    end

    test "every call emits [:engram, :nif, :call, :stop]" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :nif, :call, :stop]])
      Native.hmac_hex_many(@key, "ab", ["xyz"])
      assert_received {_, ^ref, %{input_bytes: 5}, %{nif: :hmac_hex_many}}
    end
  end
end
