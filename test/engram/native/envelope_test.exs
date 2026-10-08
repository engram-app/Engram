defmodule Engram.Native.EnvelopeTest do
  # async: false — the leak test reads a process-wide counter.
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Engram.Crypto.Envelope
  alias Engram.CryptoOracle
  alias Engram.Native

  @key :crypto.strong_rand_bytes(32)
  @aad "notes:content:0b7e2b1c-0000-4000-8000-000000000001"
  @text String.duplicate("Some markdown with [[links]] and #tags.\n", 2_000)

  describe "format 0 is byte-compatible with :crypto" do
    property "a fixed-nonce seal equals the oracle byte for byte" do
      check all(
              plain <- binary(max_length: 40_960),
              aad <- binary(max_length: 80),
              key <- binary(length: 32),
              nonce <- binary(length: 12),
              max_runs: 500
            ) do
        {{ct, ^nonce}, _peak} = Native.envelope_seal_with_nonce_nif(plain, key, aad, :none, nonce)
        assert ct == CryptoOracle.encrypt_with_nonce(plain, key, aad, nonce)
      end
    end

    property "each side opens the other's ciphertext" do
      check all(
              plain <- binary(max_length: 40_960),
              aad <- binary(max_length: 80),
              max_runs: 100
            ) do
        {ct, nonce} = CryptoOracle.encrypt(plain, @key, aad)
        assert Native.envelope_open(ct, nonce, @key, aad) == {:ok, plain}

        {ct, nonce} = Native.envelope_seal(plain, @key, aad, :none)
        assert byte_size(nonce) == 12
        assert CryptoOracle.decrypt(ct, nonce, @key, aad) == {:ok, plain}
      end
    end
  end

  describe "format 1" do
    test "round-trips under :zstd and :auto, and compresses text" do
      for mode <- [:zstd, :auto] do
        {ct, <<1, _::binary-size(12)>> = nonce} = Native.envelope_seal(@text, @key, @aad, mode)
        assert byte_size(ct) < byte_size(@text)
        assert Envelope.decrypt(ct, nonce, @key, @aad) == {:ok, @text}
      end
    end

    test "empty plaintext stays format 0 in every mode" do
      for mode <- [:none, :zstd, :auto] do
        {ct, nonce} = Native.envelope_seal("", @key, @aad, mode)
        assert byte_size(nonce) == 12
        assert byte_size(ct) == Envelope.tag_bytes()
      end
    end

    test "tampering fails closed through Envelope.decrypt/4" do
      {ct, <<1, n::binary>> = nonce} = Native.envelope_seal(@text, @key, @aad, :zstd)
      <<first, rest::binary>> = ct

      for {c, nn, k, a} <- [
            {ct, <<2, n::binary>>, @key, @aad},
            {ct, n, @key, @aad},
            {ct, nonce, @key, @aad <> "x"},
            {ct, nonce, :crypto.strong_rand_bytes(32), @aad},
            {<<Bitwise.bxor(first, 1), rest::binary>>, nonce, @key, @aad},
            {binary_part(ct, 0, 10), nonce, @key, @aad},
            {ct, <<>>, @key, @aad}
          ] do
        assert Envelope.decrypt(c, nn, k, a) == :error
      end
    end
  end

  describe "bad keys" do
    test "Native.envelope_seal raises ArgumentError, as :crypto did" do
      assert_raise ArgumentError, fn -> Native.envelope_seal("x", <<1, 2>>, "", :none) end
    end

    test "Envelope.encrypt refuses a non-32-byte key at its guard, as before" do
      assert_raise FunctionClauseError, fn -> Envelope.encrypt("x", <<1, 2>>, "") end
    end

    test "open returns :error; Envelope.decrypt/4 still refuses at its guard" do
      {ct, nonce} = Envelope.encrypt("x", @key, "")

      for bad <- [<<1, 2>>, binary_part(@key, 0, 31), @key <> "x"],
          do: assert(Native.envelope_open(ct, nonce, bad, "") == :error)

      assert_raise FunctionClauseError, fn -> Envelope.decrypt(ct, nonce, <<1, 2>>, "") end
    end
  end

  describe "scheduling" do
    test "seal: 16 KB runs on the calling scheduler, a byte more dirty" do
      Engram.NativeScheduled.assert_scheduled(
        :envelope_seal,
        &Native.envelope_seal(String.duplicate("a", &1), @key, @aad, :none)
      )
    end

    test "open: 16 KB of ciphertext runs on the calling scheduler, a byte more dirty" do
      Engram.NativeScheduled.assert_scheduled(:envelope_open, fn n ->
        {ct, nonce} = Native.envelope_seal(String.duplicate("a", n - 16), @key, @aad, :none)
        Native.envelope_open(ct, nonce, @key, @aad)
      end)
    end

    test "the inline and dirty variants agree" do
      nonce = :crypto.strong_rand_bytes(12)

      for mode <- [:none, :zstd, :auto] do
        {{ct, n}, _} = Native.envelope_seal_with_nonce_nif(@text, @key, @aad, mode, nonce)
        {inline, _} = Native.envelope_open_nif(ct, n, @key, @aad)
        {dirty, _} = Native.envelope_open_dirty_nif(ct, n, @key, @aad)
        assert inline == @text and dirty == @text

        {{ct1, n1}, _} = Native.envelope_seal_nif(@text, @key, @aad, mode)
        {{ct2, n2}, _} = Native.envelope_seal_dirty_nif(@text, @key, @aad, mode)
        assert byte_size(ct1) == byte_size(ct) and byte_size(ct2) == byte_size(ct)
        assert {:ok, @text} == Native.envelope_open(ct1, n1, @key, @aad)
        assert {:ok, @text} == Native.envelope_open(ct2, n2, @key, @aad)
      end
    end
  end

  describe "memory standard" do
    test "native peak stays within 3x a 2 MB input" do
      plain =
        @text
        |> List.duplicate(div(2_000_000, byte_size(@text)) + 1)
        |> IO.iodata_to_binary()
        |> binary_part(0, 2_000_000)

      for mode <- [:none, :zstd, :auto] do
        {{ct, nonce}, peak} = Native.envelope_seal_dirty_nif(plain, @key, @aad, mode)
        assert peak <= 3 * byte_size(plain) + 256 * 1024, "seal #{mode}: #{peak}"
        {_, peak} = Native.envelope_open_dirty_nif(ct, nonce, @key, @aad)
        assert peak <= 3 * byte_size(plain) + 256 * 1024, "open #{mode}: #{peak}"
      end
    end

    # NativeLeak warms every scheduler first, so the per-thread zstd
    # contexts exist before the counter is read (they are kept on purpose).
    test "seal + open in every mode leaks nothing" do
      Engram.NativeLeak.assert_no_leak(fn ->
        for mode <- [:none, :zstd, :auto] do
          {{ct, nonce}, _} = Native.envelope_seal_nif(@text, @key, @aad, mode)
          {_, _} = Native.envelope_open_nif(ct, nonce, @key, @aad)
        end
      end)
    end

    test "every call emits [:engram, :nif, :call, :stop]" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :nif, :call, :stop]])
      {ct, nonce} = Native.envelope_seal("abc", @key, "", :none)
      assert_received {_, ^ref, %{input_bytes: 3}, %{nif: :envelope_seal, dirty: false}}
      Native.envelope_open(ct, nonce, @key, "")
      assert_received {_, ^ref, %{input_bytes: 19}, %{nif: :envelope_open, dirty: false}}
    end
  end
end
