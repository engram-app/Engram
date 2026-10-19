defmodule Engram.Native.B64Test do
  # async: false: the leak test reads a process-wide counter.
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Engram.Native

  # Base.decode64/1 and Base.encode64/1 are the oracle: the CRDT channel
  # swapped them for these, so every answer must be identical.

  property "encode64 matches Base.encode64 and decode64 round-trips it" do
    check all(bin <- binary(max_length: 2_000), max_runs: 2_000) do
      b64 = Native.encode64(bin)
      assert b64 == Base.encode64(bin)
      assert Native.decode64(b64) == {:ok, bin}
    end
  end

  # Mostly alphabet characters plus padding, whitespace and junk, so many
  # strings are near-valid (bad length, padding in the middle, one stray byte).
  @chars ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" ++
           ~c"====-_ \n\r\t." ++ [0, 255, 128]

  property "decode64 answers exactly what Base.decode64 does on any string" do
    check all(s <- list_of(member_of(@chars), max_length: 64), max_runs: 20_000) do
      s = :erlang.list_to_binary(s)
      assert Native.decode64(s) == Base.decode64(s), "input: #{inspect(s)}"
    end
  end

  property "decode64 matches Base.decode64 on random bytes" do
    check all(s <- binary(max_length: 64), max_runs: 5_000) do
      assert Native.decode64(s) == Base.decode64(s)
    end
  end

  test "edge cases match Base.decode64" do
    for s <- [
          "",
          "QQ==",
          "QR==",
          "QUI=",
          "QUJ=",
          "QQ",
          "QQ=",
          "Q===",
          "====",
          "QQ==QQ==",
          "QUJD\n",
          "QUJD",
          "-_8="
        ] do
      assert Native.decode64(s) == Base.decode64(s), "input: #{inspect(s)}"
    end
  end

  test "decode64! returns the bytes, and raises ArgumentError like Base.decode64!" do
    bin = :crypto.strong_rand_bytes(4_096)
    assert Native.decode64!(Base.encode64(bin)) == bin
    assert Native.decode64!("") == ""

    for bad <- ["QQ", "QUJ!", "Q==="] do
      assert_raise ArgumentError, fn -> Base.decode64!(bad) end
      assert_raise ArgumentError, fn -> Native.decode64!(bad) end
    end
  end

  test "large payloads on both sides of the dirty boundary" do
    for n <- [12_288, 12_289, 16_384, 16_385, 1_000_000] do
      bin = :crypto.strong_rand_bytes(n)
      b64 = Base.encode64(bin)
      assert Native.encode64(bin) == b64
      assert Native.decode64(b64) == {:ok, bin}
      assert Native.decode64(b64 <> "!") == :error
    end
  end

  describe "memory standard" do
    # Both decode and encode write into the BEAM output binary; Rust holds nothing.
    test "native peak is zero" do
      b64 = Base.encode64(:crypto.strong_rand_bytes(100_000))
      assert {{:ok, _}, 0} = Native.b64_decode_dirty_nif(b64)
      assert {_, 0} = Native.b64_encode_dirty_nif(b64)
    end

    test "repeated calls leak nothing" do
      Engram.NativeLeak.assert_no_leak(fn ->
        Native.b64_decode_nif("QUJD")
        Native.b64_decode_nif("QUJ!")
        Native.b64_encode_nif("ABC")
      end)
    end

    # Inline calls skip the per-call event (it would cost more than the
    # decode); a dirty call emits it like every other NIF.
    test "inline calls emit no event, dirty calls do" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :nif, :call, :stop]])

      Native.decode64(String.duplicate("A", 16_384))
      Native.encode64(:binary.copy("a", 16_384))
      refute_received {_, ^ref, _, _}

      Native.decode64(String.duplicate("A", 16_388))
      assert_received {_, ^ref, %{input_bytes: 16_388}, %{nif: :b64_decode, dirty: true}}

      Native.encode64(:binary.copy("a", 16_385))
      assert_received {_, ^ref, %{input_bytes: 16_385}, %{nif: :b64_encode, dirty: true}}
    end
  end
end
