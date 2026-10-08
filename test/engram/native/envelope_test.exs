defmodule Engram.Native.EnvelopeTest do
  # async: false: the leak test reads a process-wide counter.
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Engram.Crypto.Envelope
  alias Engram.CryptoOracle
  alias Engram.Native

  @key :crypto.strong_rand_bytes(32)
  @aad "notes:content:0b7e2b1c-0000-4000-8000-000000000001"
  @text String.duplicate("Some markdown with [[links]] and #tags.\n", 2_000)
  @reps 200

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
    # Inline format-0 calls emit no event; every call is counted in the NIF
    # (Native.envelope_counts/0), and a dirty one also emits.
    test "seal: 16 KB runs on the calling scheduler, a byte more dirty" do
      assert_counted_then_dirty(:envelope_seal, fn n ->
        Native.envelope_seal(String.duplicate("a", n), @key, @aad, :none)
      end)
    end

    test "open: 16 KB of ciphertext runs on the calling scheduler, a byte more dirty" do
      inline = Native.envelope_seal(String.duplicate("a", 16_384 - 16), @key, @aad, :none)
      dirty = Native.envelope_seal(String.duplicate("a", 16_385 - 16), @key, @aad, :none)
      sealed = %{16_384 => inline, 16_385 => dirty}

      assert_counted_then_dirty(:envelope_open, fn n ->
        {ct, nonce} = sealed[n]
        Native.envelope_open(ct, nonce, @key, @aad)
      end)
    end

    test "a format-1 seal emits per call even inline" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :nif, :call, :stop]])
      Native.envelope_seal("abc", @key, @aad, :zstd)
      assert_received {_, ^ref, %{input_bytes: 3}, %{nif: :envelope_seal, dirty: false}}
    end

    # A format-1 zstd row can inflate far past its ciphertext (1.5 KB ->
    # 50 MB measured), so its size does not bound the work. The inline NIF
    # inflates only a frame that declares at most 16 KB; anything bigger
    # comes back `:reschedule` and reruns dirty.
    test "open: a small format-1 zstd row runs inline, counted, no event" do
      plain = String.duplicate("Some markdown with [[links]].\n", 35)
      {ct, <<1, _::binary-size(12)>> = nonce} = Native.envelope_seal(plain, @key, @aad, :zstd)
      assert byte_size(ct) < byte_size(plain) + 17

      assert_counted_inline(:envelope_open, byte_size(ct), fn ->
        assert Native.envelope_open(ct, nonce, @key, @aad) == {:ok, plain}
      end)
    end

    test "open: a small format-1 raw row runs inline, counted, no event" do
      {ct, <<1, _::binary-size(12)>> = nonce} = Native.envelope_seal("abc", @key, @aad, :zstd)
      assert byte_size(ct) == 3 + 1 + 16

      assert_counted_inline(:envelope_open, byte_size(ct), fn ->
        assert Native.envelope_open(ct, nonce, @key, @aad) == {:ok, "abc"}
      end)
    end

    test "open: a tiny row that inflates to 1 MB reruns dirty, counted once" do
      plain = String.duplicate("a", 1_000_000)
      {ct, <<1, _::binary-size(12)>> = nonce} = Native.envelope_seal(plain, @key, @aad, :zstd)
      assert byte_size(ct) < 200
      assert {:reschedule, _} = Native.envelope_open_nif(ct, nonce, @key, @aad)

      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :nif, :call, :stop]])
      before = counts()[:envelope_open]
      for _ <- 1..@reps, do: assert(Native.envelope_open(ct, nonce, @key, @aad) == {:ok, plain})
      # Double counting (inline try + dirty rerun) would be 2 x @reps.
      assert_delta(counts()[:envelope_open], before, {@reps, byte_size(ct) * @reps})
      size = byte_size(ct)
      assert_received {_, ^ref, %{input_bytes: ^size}, %{nif: :envelope_open, dirty: true}}
      :telemetry.detach(ref)
    end

    test "open: 16 KB of zstd plaintext inflates inline, a byte more reruns dirty" do
      for {n, dirty} <- [{16_383, false}, {16_384, false}, {16_385, true}] do
        plain = String.duplicate("a", n)
        {ct, nonce} = Native.envelope_seal(plain, @key, @aad, :zstd)
        assert byte_size(ct) < 100
        ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :nif, :call, :stop]])
        assert Native.envelope_open(ct, nonce, @key, @aad) == {:ok, plain}

        if dirty,
          do: assert_received({_, ^ref, _, %{nif: :envelope_open, dirty: true}}),
          else: refute_received({_, ^ref, _, %{nif: :envelope_open}})

        :telemetry.detach(ref)
      end
    end

    test "open: raw format 1 runs inline up to 16 KB of ciphertext, dirty past it" do
      for {n, dirty} <- [{16_384 - 17, false}, {16_385 - 17, true}] do
        plain = :crypto.strong_rand_bytes(n)
        {ct, <<1, _::binary-size(12)>> = nonce} = Native.envelope_seal(plain, @key, @aad, :auto)
        assert byte_size(ct) == n + 17
        ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :nif, :call, :stop]])
        assert Native.envelope_open(ct, nonce, @key, @aad) == {:ok, plain}

        if dirty,
          do: assert_received({_, ^ref, _, %{nif: :envelope_open, dirty: true}}),
          else: refute_received({_, ^ref, _, %{nif: :envelope_open}})

        :telemetry.detach(ref)
      end
    end

    # An authenticated frame (sealed with the real key and the format-1 AAD,
    # as only a key holder could) that declares 1 KB and decodes to 1 MB of
    # RLE blocks: the inline call stops at the declared size, never holding
    # the 1 MB, and so does the dirty one.
    test "open: a frame lying about its size never inflates past it" do
      blocks =
        for i <- 1..1024, into: <<>> do
          last = if i == 1024, do: 1, else: 0
          <<Bitwise.bor(Bitwise.bsl(1024, 3), Bitwise.bor(2, last))::little-24, ?x>>
        end

      frame = <<0x28, 0xB5, 0x2F, 0xFD, 0b1100_0000, 0, 1024::little-64, blocks::binary>>
      nonce = :crypto.strong_rand_bytes(12)
      ct = CryptoOracle.encrypt_with_nonce(<<1, frame::binary>>, @key, @aad <> "|f1", nonce)

      for nif <- [:envelope_open_nif, :envelope_open_dirty_nif] do
        assert {:error, peak} = apply(Native, nif, [ct, <<1, nonce::binary>>, @key, @aad])
        assert peak < 16_384, "#{nif}: #{peak}"
      end

      assert Native.envelope_open(ct, <<1, nonce::binary>>, @key, @aad) == :error
    end

    test "the inline and dirty variants agree" do
      nonce = :crypto.strong_rand_bytes(12)

      for mode <- [:none, :zstd, :auto] do
        {{ct, n}, _} = Native.envelope_seal_with_nonce_nif(@text, @key, @aad, mode, nonce)
        {inline, _} = Native.envelope_open_nif(ct, n, @key, @aad)
        {dirty, _} = Native.envelope_open_dirty_nif(ct, n, @key, @aad)
        # @text is 80 KB: its zstd frame is over the inline budget.
        assert inline == if(mode == :none, do: @text, else: :reschedule)
        assert dirty == @text

        {{ct1, n1}, _} = Native.envelope_seal_nif(@text, @key, @aad, mode)
        {{ct2, n2}, _} = Native.envelope_seal_dirty_nif(@text, @key, @aad, mode)
        assert byte_size(ct1) == byte_size(ct) and byte_size(ct2) == byte_size(ct)
        assert {:ok, @text} == Native.envelope_open(ct1, n1, @key, @aad)
        assert {:ok, @text} == Native.envelope_open(ct2, n2, @key, @aad)
      end
    end
  end

  # Many processes on every scheduler at once, each mode, sizes either side
  # of the 16 KB inline/dirty boundary: the thread-local zstd contexts and
  # per-call state must never cross between calls.
  test "concurrent seals and opens round-trip exactly" do
    sizes = [0, 1, 100, 16_384, 16_385, 70_000, 300_000]

    jobs =
      for i <- 1..(2 * System.schedulers_online() * 6),
          mode <- [:none, :zstd, :auto],
          do: {i, mode, Enum.at(sizes, rem(i, length(sizes)))}

    jobs
    |> Task.async_stream(
      fn {i, mode, size} ->
        plain = binary_part(String.duplicate("#{i} #{@text}", 10), 0, size)
        aad = "notes:content:#{i}"
        {ct, nonce} = Native.envelope_seal(plain, @key, aad, mode)
        {Native.envelope_open(ct, nonce, @key, aad), plain}
      end,
      max_concurrency: 2 * System.schedulers_online(),
      ordered: false
    )
    |> Enum.each(fn {:ok, {opened, plain}} -> assert opened == {:ok, plain} end)
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

    # Format 0 copies the input once, into the output BEAM binary, and runs
    # AES-GCM there: no Rust-side buffer the size of the note.
    test "format 0 seal and open hold no Rust copy of the data" do
      plain = :crypto.strong_rand_bytes(1_000_000)
      {{ct, nonce}, peak} = Native.envelope_seal_dirty_nif(plain, @key, @aad, :none)
      assert peak < 4096, "seal: #{peak}"
      {^plain, peak} = Native.envelope_open_dirty_nif(ct, nonce, @key, @aad)
      assert peak < 4096, "open: #{peak}"
    end

    # NativeLeak warms every scheduler first, so the per-thread zstd
    # contexts exist before the counter is read (they are kept on purpose).
    test "seal + open in every mode leaks nothing" do
      small = binary_part(@text, 0, 4_000)

      Engram.NativeLeak.assert_no_leak(fn ->
        for mode <- [:none, :zstd, :auto], plain <- [@text, small] do
          {{ct, nonce}, _} = Native.envelope_seal_nif(plain, @key, @aad, mode)
          {_, _} = Native.envelope_open_nif(ct, nonce, @key, @aad)
          {_, _} = Native.envelope_open_dirty_nif(ct, nonce, @key, @aad)
        end
      end)
    end

    test "inline format-0 calls are counted, not emitted" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :nif, :call, :stop]])
      before = counts()

      for _ <- 1..@reps do
        {ct, nonce} = Native.envelope_seal("abc", @key, "", :none)
        assert {:ok, "abc"} = Native.envelope_open(ct, nonce, @key, "")
      end

      now = counts()

      assert_delta(now[:envelope_seal], before[:envelope_seal], {@reps, 3 * @reps})
      assert_delta(now[:envelope_open], before[:envelope_open], {@reps, 19 * @reps})
      refute_received {_, ^ref, _, %{nif: :envelope_seal}}
      refute_received {_, ^ref, _, %{nif: :envelope_open}}
    end
  end

  # The call at 16 KB runs inline (no event); one byte more emits a dirty
  # event. Both are counted. The counters are node-global, so a stray
  # background encrypt (a draining CRDT room checkpoint) can add to them:
  # the inline phase repeats @reps times so the lower bound can only be met
  # by this test's own calls, and the upper bound (1.5x) stays tight enough
  # to catch double counting. The dirty call is attributed by its event.
  defp assert_counted_then_dirty(nif, call) do
    ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :nif, :call, :stop]])
    before = counts()[nif]
    for _ <- 1..@reps, do: call.(16_384)
    inline = counts()[nif]
    assert_delta(inline, before, {@reps, 16_384 * @reps})
    refute_received {_, ^ref, _, %{nif: ^nif}}

    call.(16_385)
    assert_delta(counts()[nif], inline, {1, 16_385})
    assert_receive {_, ^ref, %{input_bytes: 16_385}, %{nif: ^nif, dirty: true}}
    :telemetry.detach(ref)
  end

  # `call` runs inline: counted in the NIF @reps times, no per-call event.
  defp assert_counted_inline(nif, bytes, call) do
    ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :nif, :call, :stop]])
    before = counts()[nif]
    for _ <- 1..@reps, do: call.()
    assert_delta(counts()[nif], before, {@reps, bytes * @reps})
    refute_received {_, ^ref, _, %{nif: ^nif}}
    :telemetry.detach(ref)
  end

  # now - before must cover this test's own {calls, bytes} and stay within
  # 1.5x of the calls (see above).
  defp assert_delta({c1, b1}, {c0, b0}, {calls, bytes}) do
    assert c1 - c0 >= calls and c1 - c0 <= div(calls * 3, 2) + 5,
           "calls delta #{c1 - c0}, expected ~#{calls}"

    assert b1 - b0 >= bytes and b1 - b0 <= div(bytes * 3, 2) + 1_000_000,
           "bytes delta #{b1 - b0}, expected ~#{bytes}"
  end

  defp counts, do: Map.new(Native.envelope_counts(), fn {nif, c, b} -> {nif, {c, b}} end)
end
