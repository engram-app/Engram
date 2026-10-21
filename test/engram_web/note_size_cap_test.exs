defmodule EngramWeb.NoteSizeCapTest do
  @moduledoc """
  The note-size cap at its boundary, at every entry point: a note of exactly
  `Notes.max_note_bytes/0` is stored, one byte more is refused, through
  REST, MCP and a CRDT update. This is the largest note indexing has to
  handle (`Engram.IndexingHugeNotesTest` sizes its matrix from it).
  """
  use EngramWeb.ConnCase, async: false

  alias Engram.Notes
  alias Engram.Notes.CrdtBridge

  setup :authed_api_conn

  defp ascii(bytes), do: String.duplicate("a", bytes)

  test "REST: at the cap is stored, one byte over is a 413", %{conn: conn} do
    cap = Notes.max_note_bytes()
    ok = post(conn, "/api/notes", %{path: "Cap/At.md", content: ascii(cap), mtime: 1.0})
    assert %{"note" => _} = json_response(ok, 200)

    over = post(conn, "/api/notes", %{path: "Cap/Over.md", content: ascii(cap + 1), mtime: 1.0})
    assert json_response(over, 413)
  end

  test "MCP: at the cap is stored, one byte over is an error", %{conn: conn} do
    cap = Notes.max_note_bytes()

    ok = call_tool(conn, "write_note", %{"path" => "Cap/At.md", "content" => ascii(cap)})
    refute json_response(ok, 200)["result"]["isError"]

    over = call_tool(conn, "write_note", %{"path" => "Cap/Over.md", "content" => ascii(cap + 1)})
    assert json_response(over, 200)["result"]["isError"]
  end

  # The cap counts UTF-16 units of the doc (body plus frontmatter maps), so
  # for ASCII it is the byte cap.
  test "CRDT: an update to the cap fits, one byte over does not" do
    cap = Notes.max_note_bytes()
    {:ok, empty} = CrdtBridge.doc_from_state(nil)
    overhead = frontmatter_units(empty)

    assert CrdtBridge.fits?(empty, insert_update(empty, ascii(cap - overhead)))
    refute CrdtBridge.fits?(empty, insert_update(empty, ascii(cap - overhead + 1)))
  end

  # What an empty doc's frontmatter maps count against the cap.
  defp frontmatter_units(doc),
    do:
      :erlang.external_size(CrdtBridge.frontmatter_of(doc)) +
        :erlang.external_size(CrdtBridge.raw_frontmatter_of(doc))

  defp insert_update(doc, text) do
    {:ok, state} = Yex.encode_state_as_update(doc)
    {:ok, copy} = CrdtBridge.doc_from_state(state)
    {:ok, vector} = Yex.encode_state_vector(doc)
    :ok = Yex.Text.insert(Yex.Doc.get_text(copy, CrdtBridge.text_name()), 0, text)
    {:ok, update} = Yex.encode_state_as_update(copy, vector)
    update
  end
end
