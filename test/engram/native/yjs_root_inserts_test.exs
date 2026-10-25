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

  # `{live, total}` per root, sorted (client ids are random here).
  defp lengths(doc) do
    {:ok, roots} = Native.yjs_root_inserts(state(doc), "content")
    roots |> Enum.map(fn {_client, live, total} -> {live, total} end) |> Enum.sort()
  end

  defp body(doc), do: Yex.Text.to_string(Yex.Doc.get_text(doc, "content"))

  # "old text" written by one client, cleared and retyped "new text" by another.
  defp cleared_and_retyped do
    b = Yex.Doc.new()
    :ok = Yex.apply_update(b, state(seeded("old text")))
    text = Yex.Doc.get_text(b, "content")
    Yex.Text.delete(text, 0, 8)
    Yex.Text.insert(text, 0, "new text")
    b
  end

  defp doubled do
    a = seeded("first body line.\n")
    :ok = Yex.apply_update(a, state(seeded("first body line.\nsecond line.\n")))
    a
  end

  test "one lineage, edited on another device, is one root" do
    b = Yex.Doc.new()
    :ok = Yex.apply_update(b, state(seeded("first body line.\n")))
    Yex.Text.insert(Yex.Doc.get_text(b, "content"), 17, "second line.\n")
    assert lengths(b) == [{17, 17}]
  end

  test "RIVAL: a plain doubled note has two live roots" do
    a = doubled()
    {:ok, roots} = Native.yjs_root_inserts(state(a), "content")
    assert roots |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == 2
    assert lengths(a) == [{17, 17}, {30, 30}]
  end

  test "HEALTHY: clearing and retyping mints no new root" do
    # Retyping hangs off the deleted structs, so the retyping client is not a
    # root: one lineage, wholly deleted.
    assert lengths(cleared_and_retyped()) == [{0, 8}]
  end

  test "SUSPECT: a fresh seed over a cleared note keeps the dead root" do
    # One LIVE root only, yet the body is doubled. Live roots alone call this
    # healthy (the I1 false negative); the dead root beside it flags it.
    b = cleared_and_retyped()
    :ok = Yex.apply_update(b, state(seeded("new text")))
    assert body(b) == "new textnew text"
    assert lengths(b) == [{0, 8}, {8, 8}]
  end

  test "SUSPECT: a doubled doc whose rival copy was deleted keeps a dead root" do
    # Same shape as the fresh seed over a cleared note (one live, one dead);
    # only the text tells them apart, which triage reads, not the audit.
    a = doubled()
    at = if String.starts_with?(body(a), "first body line.\nsecond"), do: 0, else: 17
    Yex.Text.delete(Yex.Doc.get_text(a, "content"), at, 30)
    assert lengths(a) == [{0, 30}, {17, 17}]
  end

  test "frontmatter map entries are not body roots" do
    a = seeded("body")
    Yex.Map.set(Yex.Doc.get_map(a, "frontmatter"), "tags", "x")
    assert lengths(a) == [{4, 4}]
  end

  test "an empty doc has none; garbage is :error" do
    assert lengths(Yex.Doc.new()) == []
    assert Native.yjs_root_inserts(<<255, 255, 255>>, "content") == :error
  end

  test "emits the NIF telemetry, always dirty" do
    ref = Engram.NativeScheduled.attach_nif_events()
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
