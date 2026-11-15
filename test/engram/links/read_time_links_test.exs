defmodule Engram.Links.ReadTimeLinksTest do
  # Outgoing links of a note passed WITH its text are parsed from that text
  # at read time (`Links.links_for_notes/3`), so get_notes and the web
  # single-note response see an edit before `ExtractNoteLinks` rewrites the
  # stored rows. The tests seed stored rows that DISAGREE with the text, so a
  # read that still used them fails; the parity test seeds converged ones.
  use Engram.DataCase, async: true

  alias Engram.Fixtures
  alias Engram.Links
  alias Engram.Links.Parser
  alias Engram.Notes

  setup do
    {:ok, user} = Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp put!(user, vault, path, content) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => content, "mtime" => 1.0},
        actor: "api"
      )

    note
  end

  # The note as get_notes reads it: current text, vault id, id.
  defp read!(user, vault, path) do
    {:ok, note} = Notes.get_note(user, vault, path)
    note
  end

  # `path` holds `text`, while its stored rows still say `stale`: the window
  # between a write and its extraction job.
  defp stale_note!(user, vault, path, stale, text) do
    note = put!(user, vault, path, text)
    :ok = Links.replace_links(user, vault, note.id, Parser.extract(stale))
    read!(user, vault, path)
  end

  defp targets(links), do: Enum.map(links, &{&1.target_text, &1.target_path, &1.dangling})

  test "stale stored rows: the read returns the links of the text", %{user: u, vault: v} do
    put!(u, v, "Old.md", "old")
    put!(u, v, "New.md", "new")
    note = stale_note!(u, v, "Source.md", "[[Old]]", "see [[New]]")

    assert targets(Links.links_for_note(u, note)) == [{"New", "New.md", false}]
    # The id form still reads the stored rows (backlinks and outline keep it).
    assert targets(Links.links_for_note(u, note.id)) == [{"Old", "Old.md", false}]
  end

  test "a link removed from the text disappears", %{user: u, vault: v} do
    put!(u, v, "A.md", "a")
    put!(u, v, "B.md", "b")
    note = stale_note!(u, v, "Source.md", "[[A]] [[B]]", "[[A]]")

    assert targets(Links.links_for_note(u, note)) == [{"A", "A.md", false}]
  end

  test "an added folder-qualified link resolves to that path", %{user: u, vault: v} do
    put!(u, v, "Deep.md", "short")
    put!(u, v, "Folder/Deep.md", "pathed")
    note = stale_note!(u, v, "Source.md", "", "[[Folder/Deep]]")

    assert targets(Links.links_for_note(u, note)) == [{"Folder/Deep", "Folder/Deep.md", false}]
  end

  test "an unresolved link stays unresolved", %{user: u, vault: v} do
    note = stale_note!(u, v, "Source.md", "", "[[Nope]]")

    assert [%{target_text: "Nope", target_note_id: nil, dangling: true}] =
             Links.links_for_note(u, note)
  end

  test "a note created after the link resolves at once", %{user: u, vault: v} do
    note = stale_note!(u, v, "Source.md", "", "[[Later]]")
    assert [%{dangling: true}] = Links.links_for_note(u, note)

    later = put!(u, v, "x/Later.md", "here")

    assert [%{target_note_id: id, target_path: "x/Later.md", dangling: false}] =
             Links.links_for_note(u, note)

    assert id == later.id
  end

  # Parity: on a converged note (stored rows extracted from the same text)
  # both paths return the same list, field for field.
  test "read-time links equal stored links on a converged note", %{user: u, vault: v} do
    put!(u, v, "Beta.md", "# Sec\n")
    put!(u, v, "Sub/Gamma.md", "g")
    put!(u, v, "Other/Gamma.md", "o")
    Fixtures.insert_attachments!(u, v, [%{path: "img.png"}])

    text = """
    [[Beta#Sec]] [[Beta|b]] ![[img.png]] [x](Beta.md) [[beta]] [[Sub/Gamma]] [[Ghost]]
    """

    note = put!(u, v, "Source.md", text)
    :ok = Links.replace_links(u, v, note.id, Parser.extract(text))
    note = read!(u, v, "Source.md")

    stored = Links.links_for_note(u, note.id)
    assert length(stored) == 7
    assert Links.links_for_note(u, note) == stored
  end

  test "a tripped parse deadline falls back to the stored rows", %{user: u, vault: v} do
    put!(u, v, "Old.md", "old")
    put!(u, v, "New.md", "new")
    # Over the inline size, so the parse goes through Engram.MCP.ParseGate.
    pad = String.duplicate("x", Engram.Native.inline_max() + 1)
    note = stale_note!(u, v, "Source.md", "[[Old]]", "[[New]] " <> pad)

    # Control: the gated parse itself works.
    assert targets(Links.links_for_note(u, note)) == [{"New", "New.md", false}]

    Process.put(:engram_parse_gate_opts, deadline: System.monotonic_time(:millisecond) - 1)
    assert targets(Links.links_for_note(u, note)) == [{"Old", "Old.md", false}]
  end

  test "a note over the per-note size falls back to the stored rows", %{user: u, vault: v} do
    put!(u, v, "Old.md", "old")
    note = put!(u, v, "Source.md", "x")
    :ok = Links.replace_links(u, v, note.id, Parser.extract("[[Old]]"))
    note = read!(u, v, "Source.md")

    huge = %{note | content: "[[New]] " <> String.duplicate("x", 1_048_576)}
    assert targets(Links.links_for_note(u, huge)) == [{"Old", "Old.md", false}]
  end

  test "a batch over the note cap falls back to the stored rows", %{user: u, vault: v} do
    put!(u, v, "Old.md", "old")
    put!(u, v, "New.md", "new")

    notes =
      for i <- 1..21 do
        note = put!(u, v, "S#{i}.md", "[[New]]")
        :ok = Links.replace_links(u, v, note.id, Parser.extract("[[Old]]"))
        read!(u, v, "S#{i}.md")
      end

    over = Links.links_for_notes(u, notes)
    assert Enum.all?(notes, &(targets(over[&1.id]) == [{"Old", "Old.md", false}]))

    # Control at the cap: 20 notes parse their text.
    at = Links.links_for_notes(u, Enum.take(notes, 20))
    assert Enum.all?(Enum.take(notes, 20), &(targets(at[&1.id]) == [{"New", "New.md", false}]))
  end

  test "a note with no text loaded reads the stored rows", %{user: u, vault: v} do
    put!(u, v, "Old.md", "old")
    note = stale_note!(u, v, "Source.md", "[[Old]]", "[[New]]")

    assert targets(Links.links_for_note(u, %{note | content: nil})) == [{"Old", "Old.md", false}]
  end
end
