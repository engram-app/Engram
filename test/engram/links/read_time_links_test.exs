defmodule Engram.Links.ReadTimeLinksTest do
  # Outgoing links of a note passed WITH its text are parsed from that text
  # at read time (`Links.links_for_notes/2`), so get_notes and the web
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

  # `@read_parse_budget` in Engram.Links: text parsed per call.
  @budget 512 * 1024

  defp padded(text, size), do: text <> String.duplicate("x", size - byte_size(text))

  test "a note over the per-call byte budget reads its stored rows", %{user: u, vault: v} do
    put!(u, v, "Old.md", "old")
    put!(u, v, "New.md", "new")
    note = stale_note!(u, v, "Source.md", "[[Old]]", "[[New]]")

    # Control at the budget: parsed.
    at = %{note | content: padded("[[New]] ", @budget)}
    assert targets(Links.links_for_note(u, at)) == [{"New", "New.md", false}]

    over = %{note | content: padded("[[New]] ", @budget + 1)}
    assert targets(Links.links_for_note(u, over)) == [{"Old", "Old.md", false}]
  end

  test "the budget is per call: a note past what is left reads its stored rows",
       %{user: u, vault: v} do
    put!(u, v, "Old.md", "old")
    put!(u, v, "New.md", "new")

    [a, b, c] =
      for {path, size} <- [{"A.md", 300 * 1024}, {"B.md", 300 * 1024}, {"C.md", 8}],
          do: stale_note!(u, v, path, "[[Old]]", padded("[[New]] ", size))

    got = Links.links_for_notes(u, [a, b, c])

    assert targets(got[a.id]) == [{"New", "New.md", false}]
    assert targets(got[b.id]) == [{"Old", "Old.md", false}]
    # A smaller note after it still fits.
    assert targets(got[c.id]) == [{"New", "New.md", false}]
  end

  # Link parsing is linear and bounded by the byte budget, so it never queues
  # on Engram.MCP.ParseGate (one slot in prod, shared with outline parses):
  # with every gated run refused, a large note still parses its text.
  test "a large note parses with the parse gate refusing everything", %{user: u, vault: v} do
    put!(u, v, "Old.md", "old")
    put!(u, v, "New.md", "new")
    note = stale_note!(u, v, "Source.md", "[[Old]]", padded("[[New]] ", 64 * 1024))

    Process.put(:engram_parse_gate_opts, deadline: System.monotonic_time(:millisecond) - 1)
    assert Engram.MCP.ParseGate.run(fn -> :ran end) == {:error, :deadline}

    assert targets(Links.links_for_note(u, note)) == [{"New", "New.md", false}]
  end

  test "a note with nothing to resolve opens no transaction", %{user: u, vault: v} do
    note = stale_note!(u, v, "Source.md", "[[Old]]", "no links")
    me = self()

    {links, queries} = Engram.QueryRecorder.record(fn -> Links.links_for_note(u, note) end)
    assert links == []
    assert Enum.filter(queries, &(&1.pid == me)) == []
  end

  test "a note with no text loaded reads the stored rows", %{user: u, vault: v} do
    put!(u, v, "Old.md", "old")
    note = stale_note!(u, v, "Source.md", "[[Old]]", "[[New]]")

    assert targets(Links.links_for_note(u, %{note | content: nil})) == [{"Old", "Old.md", false}]
  end
end
