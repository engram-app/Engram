defmodule Engram.Native.YjsRootInsertsTest do
  use ExUnit.Case, async: true

  alias Engram.Native

  defp seeded(text) do
    doc = Yex.Doc.new()
    Yex.Text.insert(Yex.Doc.get_text(doc, "content"), 0, text)
    doc
  end

  defp state(doc) do
    {:ok, update} = Yex.encode_state_as_update(doc)
    update
  end

  defp root_clients(update) do
    {:ok, roots} = Native.yjs_root_inserts(update, "content")
    roots |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length()
  end

  test "one lineage, edited on another device, is one root client" do
    a = seeded("first body line.\n")
    b = Yex.Doc.new()
    :ok = Yex.apply_update(b, state(a))
    Yex.Text.insert(Yex.Doc.get_text(b, "content"), 17, "second line.\n")
    assert root_clients(state(b)) == 1
  end

  test "a fresh device seeding an existing note is two, with both lengths" do
    a = seeded("first body line.\n")
    :ok = Yex.apply_update(a, state(seeded("first body line.\nsecond line.\n")))
    {:ok, roots} = Native.yjs_root_inserts(state(a), "content")
    assert roots |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == 2
    assert roots |> Enum.map(&elem(&1, 1)) |> Enum.sort() == [17, 30]
  end

  test "a doubled doc whose rival copy was deleted reports one live root" do
    a = seeded("first body line.\n")
    :ok = Yex.apply_update(a, state(seeded("first body line.\nsecond line.\n")))
    text = Yex.Doc.get_text(a, "content")

    at =
      if String.starts_with?(Yex.Text.to_string(text), "first body line.\nsecond"),
        do: 0,
        else: 17

    Yex.Text.delete(text, at, 30)

    assert {:ok, [{_, 17}]} = Native.yjs_root_inserts(state(a), "content")
  end

  test "clearing and retyping mints no new root" do
    a = seeded("old text")
    b = Yex.Doc.new()
    :ok = Yex.apply_update(b, state(a))
    text = Yex.Doc.get_text(b, "content")
    Yex.Text.delete(text, 0, 8)
    Yex.Text.insert(text, 0, "new text")
    # Retyping hangs off a's deleted structs, so b is not a root; a's root is
    # wholly deleted, so no LIVE lineage remains (I3). Healthy, never a rival.
    assert root_clients(state(b)) == 0
  end

  test "frontmatter map entries are not body roots" do
    a = seeded("body")
    Yex.Map.set(Yex.Doc.get_map(a, "frontmatter"), "tags", "x")
    assert root_clients(state(a)) == 1
  end

  test "an empty doc has none; garbage is :error" do
    assert root_clients(state(Yex.Doc.new())) == 0
    assert Native.yjs_root_inserts(<<255, 255, 255>>, "content") == :error
  end

  test "emits the NIF telemetry, always dirty" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :nif, :call, :stop]])
    update = state(seeded("x"))
    Native.yjs_root_inserts(update, "content")
    size = byte_size(update)
    assert_receive {_, ^ref, %{input_bytes: ^size}, %{nif: :yjs_root_inserts, dirty: true}}
    :telemetry.detach(ref)
  end

  test "peak stays linear in the update" do
    update = state(seeded(String.duplicate("line of text\n", 200_000)))
    {_, peak} = Native.yjs_root_inserts_nif(update, "content")
    assert peak <= 3 * byte_size(update) + 1_000_000, "#{peak} for #{byte_size(update)} B"
  end

  test "repeated calls leak nothing" do
    update = state(seeded("a\nb\n"))
    Engram.NativeLeak.assert_no_leak(fn -> Native.yjs_root_inserts_nif(update, "content") end)
  end
end
