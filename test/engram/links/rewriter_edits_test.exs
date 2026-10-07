defmodule Engram.Links.RewriterEditsTest do
  # Pure: no DB, no rooms. Differential against the edit code the rewriter
  # used before #1877 (a whole-note copy per splice edit, a prefix
  # conversion per CRDT edit), kept here as the oracle.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Engram.Links.Rewriter
  alias Engram.Notes.CrdtBridge

  defp old_splice(text, edits) do
    edits
    |> Enum.sort_by(& &1.rel_start, :desc)
    |> Enum.reduce(text, fn e, acc ->
      binary_part(acc, 0, e.rel_start) <>
        e.new <>
        binary_part(acc, e.rel_start + e.len, byte_size(acc) - e.rel_start - e.len)
    end)
  end

  defp u16(s),
    do: s |> :unicode.characters_to_binary(:utf8, {:utf16, :big}) |> byte_size() |> div(2)

  defp old_apply(doc, body, edits) do
    text = Yex.Doc.get_text(doc, CrdtBridge.text_name())

    Yex.Doc.transaction(doc, "link_rewrite", fn ->
      edits
      |> Enum.sort_by(& &1.rel_start, :desc)
      |> Enum.each(fn e ->
        off = u16(binary_part(body, 0, e.rel_start))
        Yex.Text.delete(text, off, u16(binary_part(body, e.rel_start, e.len)))
        Yex.Text.insert(text, off, e.new)
      end)
    end)
  end

  defp doc_of(body) do
    doc = CrdtBridge.new_doc()
    Yex.Text.insert(Yex.Doc.get_text(doc, CrdtBridge.text_name()), 0, body)
    doc
  end

  defp text_of(doc), do: Yex.Text.to_string(Yex.Doc.get_text(doc, CrdtBridge.text_name()))

  @units ["a", " ", "\n", "é", "€", "📝", "🚀", "中", <<0x301::utf8>>]
  @targets ["Old", "Ö📝", "🚀🚀", "a b", ""]

  defp piece do
    StreamData.one_of([
      StreamData.member_of(@units),
      StreamData.member_of(@targets) |> StreamData.map(&"[[#{&1}]]")
    ])
  end

  # A note with links, and an edit per link (in random order) replacing its
  # target with random text, astral included.
  defp note_and_edits do
    gen all(
          pieces <- StreamData.list_of(piece(), max_length: 60),
          news <- StreamData.list_of(StreamData.member_of(@units ++ @targets), length: 60)
        ) do
      body = Enum.join(pieces)

      edits =
        ~r/\[\[([^\]]*)\]\]/u
        |> Regex.scan(body, return: :index)
        |> Enum.zip(news)
        |> Enum.map(fn {[_, {at, len}], new} -> %{rel_start: at, len: len, new: new} end)
        |> Enum.shuffle()

      {body, edits}
    end
  end

  property "splice matches the per-edit copy" do
    check all({body, edits} <- note_and_edits(), max_runs: 1_000) do
      assert Rewriter.splice(body, edits) == old_splice(body, edits)
    end
  end

  property "apply_edits! lands each edit where the per-edit conversion did" do
    check all({body, edits} <- note_and_edits(), max_runs: 500) do
      new_doc = doc_of(body)
      old_doc = doc_of(body)
      :ok = Rewriter.apply_edits!(new_doc, body, edits)
      old_apply(old_doc, body, edits)

      assert text_of(new_doc) == text_of(old_doc)
      assert text_of(new_doc) == old_splice(body, edits)
    end
  end

  test "no edits and an empty note" do
    assert Rewriter.splice("", []) == ""
    assert Rewriter.splice("abc", []) == "abc"
    doc = doc_of("abc")
    :ok = Rewriter.apply_edits!(doc, "abc", [])
    assert text_of(doc) == "abc"
  end

  test "edits at the very start and end" do
    edits = [%{rel_start: 0, len: 1, new: "📝"}, %{rel_start: 2, len: 1, new: "🚀"}]
    assert Rewriter.splice("abc", edits) == "📝b🚀"
    doc = doc_of("abc")
    :ok = Rewriter.apply_edits!(doc, "abc", edits)
    assert text_of(doc) == "📝b🚀"
  end
end
