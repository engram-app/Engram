defmodule Engram.Native.JsonDecodeTest do
  # async: false — the leak test reads a process-wide counter.
  use ExUnit.Case, async: false

  alias Engram.Native

  @docs [
    ~s({}),
    ~s([]),
    ~s({"a":1,"a":2.5,"b":{"c":true,"c":false}}),
    ~s({"n":[0,-0,1,-1,1.0,-0.0,1e5,1E-7,2.5e+3,18446744073709551615,-9223372036854775808]}),
    ~s({"s":"\\u00e9\\ud83d\\ude42 \\"q\\" \\\\ \\n\\t","u":"東京","e":""}),
    ~s({"t":true,"f":false,"z":null,"deep":{"a":[{"b":[[]]}]}}),
    ~s(  [1, 2 ,3 ]  ),
    ~s("bare string"),
    ~s(42),
    ~s(0.30000000000000004)
  ]

  test "returns exactly what Jason.decode/1 returns" do
    for doc <- @docs do
      assert Native.json_decode(doc) == Jason.decode(doc), doc
    end
  end

  # The shape it exists for: a Qdrant query response with dense vectors.
  test "a search response with vectors decodes identically, floats bit for bit" do
    :rand.seed(:exsss, {3, 1, 4})

    points =
      for i <- 1..60 do
        %{
          "id" => "00000000-0000-0000-0000-#{String.pad_leading("#{i}", 12, "0")}",
          "score" => :rand.uniform(),
          "payload" => %{"text" => "chunk #{i} ✓", "aad_version" => 2},
          "vector" => %{"dense" => for(_ <- 1..1024, do: :rand.uniform() - 0.5)}
        }
      end

    body = Jason.encode!(%{"result" => %{"points" => points}, "status" => "ok", "time" => 0.01})
    assert byte_size(body) > 16_384, "fixture must exercise the dirty path"
    assert Native.json_decode(body) == Jason.decode(body)
  end

  # Documented difference: serde reports "-0" as the float -0.0, Jason as the
  # integer 0. Qdrant never emits it; pinned so a change is deliberate.
  test "-0 decodes as -0.0" do
    assert Native.json_decode("-0") == {:ok, -0.0}
  end

  test "malformed text is an error, never a partial decode" do
    for bad <- ["{", "", "[1,]", "nul", ~s({"a":1}x)] do
      assert Native.json_decode(bad) == {:error, :invalid_json}, bad
    end
  end

  # Documented limit: serde_json stops at 128 levels where Jason has none.
  # Qdrant responses nest a handful deep.
  test "nesting past 128 levels is refused" do
    assert {:ok, _} = Native.json_decode(String.duplicate("[", 120) <> String.duplicate("]", 120))
    deep = String.duplicate("[", 200) <> String.duplicate("]", 200)
    assert Native.json_decode(deep) == {:error, :invalid_json}
  end

  describe "memory standard" do
    # The serde Value tree is the transient: bounded by a multiple of the text.
    test "native peak stays within a small multiple of the input" do
      body =
        Jason.encode!(%{"points" => for(_ <- 1..200, do: for(_ <- 1..1024, do: :rand.uniform()))})

      {_, peak} = Native.json_decode_dirty_nif(body)
      assert peak <= 4 * byte_size(body) + 65_536
    end

    test "repeated calls leak nothing" do
      doc = ~s({"a":[1,2.5,"x",{"b":null}]})
      Native.json_decode_nif(doc)
      before = Native.live_bytes()
      for _ <- 1..300, do: Native.json_decode_nif(doc)
      assert Native.live_bytes() - before == 0
    end

    test "every call emits [:engram, :nif, :call, :stop]" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :nif, :call, :stop]])
      Native.json_decode("[1]")
      assert_received {_, ^ref, %{input_bytes: 3}, %{nif: :json_decode}}
    end
  end
end
