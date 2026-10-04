defmodule Engram.Native.VectorJsonTest do
  # async: false — the leak test reads a process-wide counter.
  use ExUnit.Case, async: false

  alias Engram.Native

  # The Elixir code these NIFs replaced, kept as the parity oracle.
  defp old_pack(vector), do: for(x <- vector, into: <<>>, do: <<x::float-32-little>>)

  defp old_dense_json(packed) do
    floats = for <<x::float-32-little <- packed>>, do: :erlang.float_to_binary(x, [:short])
    IO.iodata_to_binary(["[", Enum.intersperse(floats, ","), "]"])
  end

  defp old_sparse_json(indices, values) do
    ids = for <<d::unsigned-little-32 <- indices>>, do: Integer.to_string(d)
    ws = for <<w::float-little-64 <- values>>, do: :erlang.float_to_binary(w, [:short])

    IO.iodata_to_binary([
      ~s({"indices":[),
      Enum.intersperse(ids, ","),
      ~s(],"values":[),
      Enum.intersperse(ws, ","),
      "]}"
    ])
  end

  defp random_floats(n),
    do: for(_ <- 1..n, do: (:rand.uniform() - 0.5) * :math.pow(10, :rand.uniform(12) - 8))

  setup do
    :rand.seed(:exsss, {11, 12, 13})
    :ok
  end

  describe "pack_f32/1" do
    test "packs exactly like the Elixir binary construction, integers included" do
      for _ <- 1..200 do
        vector = random_floats(64) ++ [0, 1, -3, 0.0, -0.0]
        assert Native.pack_f32(vector) == old_pack(vector)
      end
    end

    test "refuses a value outside f32 range and a non-number" do
      assert_raise ArgumentError, fn -> Native.pack_f32([1.0e300]) end
      assert_raise ArgumentError, fn -> Native.pack_f32([1.0, :x]) end
    end
  end

  describe "dense_json/1" do
    # The text differs on purpose (shortest f32 instead of widened f64), so
    # parity is on the f32 the receiver stores: decode, narrow, repack.
    test "every value reads back as the exact f32 that was packed" do
      for _ <- 1..200 do
        packed = old_pack(random_floats(1024))
        decoded = packed |> Native.dense_json() |> Jason.decode!()

        assert old_pack(decoded) == packed
        assert length(decoded) == length(Jason.decode!(old_dense_json(packed)))
      end
    end

    test "is shorter than the widened-f64 text" do
      packed = old_pack(random_floats(1024))
      assert byte_size(Native.dense_json(packed)) < byte_size(old_dense_json(packed))
    end

    test "empty, ragged and non-finite inputs" do
      assert Native.dense_json(<<>>) == "[]"
      assert_raise ArgumentError, fn -> Native.dense_json(<<0, 0, 0>>) end
      # f32 NaN and +infinity bit patterns.
      assert_raise ArgumentError, fn -> Native.dense_json(<<0, 0, 192, 127>>) end
      assert_raise ArgumentError, fn -> Native.dense_json(<<0, 0, 128, 127>>) end
    end
  end

  describe "sparse_json/2" do
    test "decodes to the same indices and values as the Elixir text" do
      for _ <- 1..200 do
        n = :rand.uniform(300)

        indices =
          for _ <- 1..n, into: <<>>, do: <<:rand.uniform(4_294_967_295)::unsigned-little-32>>

        values = for w <- random_floats(n), into: <<>>, do: <<abs(w)::float-little-64>>

        assert Jason.decode!(Native.sparse_json(indices, values)) ==
                 Jason.decode!(old_sparse_json(indices, values))
      end
    end

    test "empty and mismatched inputs" do
      assert Native.sparse_json(<<>>, <<>>) == ~s({"indices":[],"values":[]})
      assert_raise ArgumentError, fn -> Native.sparse_json(<<1::32>>, <<>>) end
      assert_raise ArgumentError, fn -> Native.sparse_json(<<1, 2>>, <<1.0::float-64>>) end
    end
  end

  describe "memory standard" do
    # Output text is at most ~16 bytes per f32 and ~25 per sparse pair; the
    # peak is that one buffer (its BEAM copy is not Rust heap).
    test "native peak stays within the output buffer" do
      packed = old_pack(random_floats(4096))
      {_, peak} = Native.dense_json_nif(packed)
      assert peak <= 15 * 4096 + 4_096

      {_, peak} = Native.pack_f32_nif(random_floats(4096))
      assert peak <= 8 * 4096 + 4 * 4096 + 4_096

      indices = for i <- 1..2_000, into: <<>>, do: <<i::unsigned-little-32>>
      values = for _ <- 1..2_000, into: <<>>, do: <<:rand.uniform()::float-little-64>>
      {_, peak} = Native.sparse_json_nif(indices, values)
      assert peak <= 3 * 2_000 * 12 + 4_096
    end

    test "repeated calls leak nothing" do
      packed = old_pack(random_floats(256))
      floats = random_floats(256)

      sparse =
        {<<1::unsigned-little-32, 9::unsigned-little-32>>,
         <<0.5::float-little-64, 2.0::float-little-64>>}

      run = fn ->
        Native.dense_json_nif(packed)
        Native.pack_f32_nif(floats)
        Native.sparse_json_nif(elem(sparse, 0), elem(sparse, 1))
      end

      run.()
      before = Native.live_bytes()
      for _ <- 1..300, do: run.()
      assert Native.live_bytes() - before == 0
    end

    test "every call emits [:engram, :nif, :call, :stop]" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :nif, :call, :stop]])
      Native.pack_f32([1.0])
      Native.dense_json(<<1.0::float-32-little>>)
      Native.sparse_json(<<1::32>>, <<1.0::float-64>>)

      assert_received {_, ^ref, %{input_bytes: 8}, %{nif: :pack_f32}}
      assert_received {_, ^ref, %{input_bytes: 4}, %{nif: :dense_json}}
      assert_received {_, ^ref, %{input_bytes: 12}, %{nif: :sparse_json}}
    end
  end
end
