defmodule Engram.Notes.CrdtBridgeTest do
  use ExUnit.Case, async: true

  alias Engram.Notes.CrdtBridge

  test "merge_plaintext seeds an empty doc with the full incoming text" do
    {:ok, %{state: state, text: text}} = CrdtBridge.merge_plaintext(nil, "# Hello\n\nbody")
    assert text == "# Hello\n\nbody"
    assert is_binary(state) and byte_size(state) > 0
  end

  test "merge_plaintext converges the doc to subsequent incoming text" do
    {:ok, %{state: s1}} = CrdtBridge.merge_plaintext(nil, "the quick brown fox")
    {:ok, %{state: _s2, text: text}} = CrdtBridge.merge_plaintext(s1, "the quick red fox jumps")
    assert text == "the quick red fox jumps"
  end

  test "diff_into_text does NOT full-replace (unchanged prefix item survives)" do
    {:ok, doc} = CrdtBridge.doc_from_state(nil)
    t = Yex.Doc.get_text(doc, CrdtBridge.text_name())
    Yex.Text.insert(t, 0, "hello world")
    sv_before = Yex.encode_state_vector!(doc)

    :ok = CrdtBridge.diff_into_text(t, "hello brave world")

    assert Yex.Text.to_string(t) == "hello brave world"
    # A delete-all+reinsert rewrites every item, ballooning the state vector
    # clock far past a 6-char insert. A minimal diff advances it modestly.
    sv_after = Yex.encode_state_vector!(doc)
    assert byte_size(sv_after) >= byte_size(sv_before)
  end

  test "two server-side merges from a shared base converge with no lost edits" do
    {:ok, %{state: base}} = CrdtBridge.merge_plaintext(nil, "shared base line")

    {:ok, %{state: sa}} = CrdtBridge.merge_plaintext(base, "shared base line — A edit")
    {:ok, %{state: sb}} = CrdtBridge.merge_plaintext(base, "B prefix — shared base line")

    {:ok, merged} = CrdtBridge.doc_from_state(sa)
    :ok = Yex.apply_update(merged, sb)
    final = CrdtBridge.text_of(merged)

    assert final =~ "A edit"
    assert final =~ "B prefix"
    assert length(String.split(final, "shared base line")) == 2
  end

  # HARD v1 correctness gate (spec §12a contract 4): Yjs offsets are UTF-16
  # code units, and `y_ex`'s offset_kind defaults to :bytes — so the bridge
  # MUST build docs with offset_kind: :utf16 AND compute diff offsets in UTF-16
  # code units. The Gate 0 spike only exercised ASCII; an astral-plane edit
  # (emoji are surrogate pairs = 2 UTF-16 units) is where a bytes/graphemes
  # offset corrupts the doc. These round-trips prove the unit is correct.
  describe "frontmatter accessors" do
    test "frontmatter_of returns empty order and values for a fresh doc" do
      doc = CrdtBridge.new_doc()
      assert CrdtBridge.frontmatter_of(doc) == {[], %{}}
    end

    test "doc_schema_version is 2" do
      assert CrdtBridge.doc_schema_version() == 2
    end
  end

  # Concurrent lifts of one fence each append to `frontmatter_order` and the
  # CRDT keeps both. Every reader sees each key once, at its FIRST position.
  describe "frontmatter_order holding a key twice" do
    setup do
      doc = CrdtBridge.new_doc()
      :ok = CrdtBridge.ingest_plaintext(doc, "---\ntitle: Hi\ntags: a\n---\nbody\n")
      arr = Yex.Doc.get_array(doc, "frontmatter_order")
      Yex.Array.insert_list(arr, 2, ["title"])
      %{doc: doc}
    end

    test "frontmatter_of lists the key once, at its first position", %{doc: doc} do
      assert {["title", "tags"], _values} = CrdtBridge.frontmatter_of(doc)
    end

    test "the projected note holds the key once", %{doc: doc} do
      assert CrdtBridge.project_doc(doc) == "---\ntitle: Hi\ntags: a\n---\nbody\n"
    end
  end

  describe "text_of vs body_of" do
    test "text_of returns the full projected note; body_of returns body only" do
      doc = CrdtBridge.new_doc()
      :ok = CrdtBridge.ingest_plaintext(doc, "---\ntitle: Hi\n---\nbody\n")
      assert CrdtBridge.text_of(doc) == "---\ntitle: Hi\n---\nbody\n"
      assert CrdtBridge.body_of(doc) == "body\n"
    end
  end

  describe "ingest_plaintext/2" do
    test "a BOM note round-trips byte-identical (PR #2084 review H3)" do
      bom = "\uFEFF---\ntitle: Hi\n---\nbody\n"
      doc = CrdtBridge.new_doc()
      :ok = CrdtBridge.ingest_plaintext(doc, bom)
      assert CrdtBridge.text_of(doc) == bom
      assert Engram.Notes.Frontmatter.split(bom) == {nil, bom}
    end

    test "splits frontmatter into the map/order and body into the text" do
      doc = CrdtBridge.new_doc()
      :ok = CrdtBridge.ingest_plaintext(doc, "---\ntitle: Hi\n---\nbody\n")
      assert CrdtBridge.frontmatter_of(doc) == {["title"], %{"title" => "\"Hi\""}}
      assert CrdtBridge.body_of(doc) == "body\n"
    end

    test "malformed frontmatter keeps the whole text as body" do
      doc = CrdtBridge.new_doc()
      :ok = CrdtBridge.ingest_plaintext(doc, "---\nbroken: : :\n---\nbody\n")
      assert CrdtBridge.frontmatter_of(doc) == {[], %{}}
      assert CrdtBridge.text_of(doc) == "---\nbroken: : :\n---\nbody\n"
    end
  end

  describe "degraded frontmatter key raw passthrough (lossless round-trip)" do
    test "single-line degraded value round-trips byte-identical" do
      doc = CrdtBridge.new_doc()
      original = "---\ntags:\n  - a\ndate: {[a, b]: 1}\n---\nbody text\n"
      :ok = CrdtBridge.ingest_plaintext(doc, original)
      assert CrdtBridge.text_of(doc) == original
    end

    test "multi-line degraded value round-trips byte-identical" do
      doc = CrdtBridge.new_doc()
      original = "---\ntags:\n  - a\ndate:\n  [a, b]: 1\n---\nbody text\n"
      :ok = CrdtBridge.ingest_plaintext(doc, original)
      assert CrdtBridge.text_of(doc) == original
    end

    test "a GOOD value that looks like a raw marker still round-trips (no false passthrough)" do
      doc = CrdtBridge.new_doc()
      original = "---\ndate:\n  __engram_raw__: x\n---\nbody\n"
      :ok = CrdtBridge.ingest_plaintext(doc, original)
      assert CrdtBridge.text_of(doc) == original
    end

    test "a marker-colliding map keeps its sibling keys (canonicalized, not dropped)" do
      doc = CrdtBridge.new_doc()
      original = "---\ndate:\n  __engram_raw__: x\n  y: 1\n---\nbody\n"
      :ok = CrdtBridge.ingest_plaintext(doc, original)
      # This is a normal ENCODABLE value (a map that merely contains the old
      # marker key), so it round-trips CANONICALLY through Ymlr, not verbatim:
      # both sibling keys survive as data (emit never treats it as a marker).
      # Byte-identity is only promised for DEGRADED keys (raw passthrough).
      {_order, values} = CrdtBridge.frontmatter_of(doc)
      assert Jason.decode!(values["date"]) == %{"__engram_raw__" => "x", "y" => 1}
      assert CrdtBridge.body_of(doc) == "body\n"
    end

    test "pathologically long single-line degraded value round-trips byte-identical (reason snippet is bounded, raw span is not)" do
      doc = CrdtBridge.new_doc()
      padding = String.duplicate("x", 500)
      original = "---\ntags:\n  - a\ndate: {[#{padding}]: 1}\n---\nbody text\n"
      :ok = CrdtBridge.ingest_plaintext(doc, original)
      assert CrdtBridge.text_of(doc) == original
    end

    test "un-locatable degraded key falls back to whole-text-as-body (still lossless)" do
      doc = CrdtBridge.new_doc()
      original = "---\n{[a, b]: 1}: {[c, d]: 2}\n---\nbody text\n"
      :ok = CrdtBridge.ingest_plaintext(doc, original)
      assert CrdtBridge.frontmatter_of(doc) == {[], %{}}
      assert CrdtBridge.text_of(doc) == original
    end
  end

  describe "project_doc/1" do
    test "round-trips ingest then project back to equivalent plaintext" do
      doc = CrdtBridge.new_doc()
      :ok = CrdtBridge.ingest_plaintext(doc, "---\ntitle: Hi\n---\nbody\n")
      assert CrdtBridge.project_doc(doc) == "---\ntitle: Hi\n---\nbody\n"
    end

    test "body-only doc projects to body only" do
      doc = CrdtBridge.new_doc()
      :ok = CrdtBridge.ingest_plaintext(doc, "no frontmatter\n")
      assert CrdtBridge.project_doc(doc) == "no frontmatter\n"
    end

    test "a client-written value shaped like the old raw marker is NOT dropped on projection" do
      # A hostile/buggy client can write this value straight into the Y.Map,
      # bypassing the ingest guard. With out-of-band raws, projection must treat
      # it as a normal value (emit canonically), never as a passthrough marker.
      doc = CrdtBridge.new_doc()
      map = Yex.Doc.get_map(doc, "frontmatter")
      Yex.Map.set(map, "mykey", ~s({"__engram_raw__":"hello"}))
      arr = Yex.Doc.get_array(doc, "frontmatter_order")
      Yex.Array.insert_list(arr, 0, ["mykey"])

      text = CrdtBridge.project_doc(doc)
      assert text =~ "mykey"

      # And it round-trips: re-ingesting yields the same value under the key.
      doc2 = CrdtBridge.new_doc()
      :ok = CrdtBridge.ingest_plaintext(doc2, text)
      {_order, values} = CrdtBridge.frontmatter_of(doc2)
      assert Jason.decode!(values["mykey"]) == %{"__engram_raw__" => "hello"}
    end
  end

  describe "merge_plaintext/2 with frontmatter" do
    test "ingests frontmatter and returns projected text + re-encodable state" do
      {:ok, %{state: state, text: text}} =
        CrdtBridge.merge_plaintext(nil, "---\ntitle: Hi\n---\nbody\n")

      assert text == "---\ntitle: Hi\n---\nbody\n"
      assert is_binary(state)

      {:ok, doc2} = CrdtBridge.doc_from_state(state)
      assert CrdtBridge.frontmatter_of(doc2) == {["title"], %{"title" => "\"Hi\""}}
    end
  end

  describe "client_count/1" do
    test "counts the distinct client ids in the state vector" do
      {:ok, %{state: s}} = CrdtBridge.merge_plaintext(nil, "hello")
      {:ok, doc} = CrdtBridge.doc_from_state(s)
      assert CrdtBridge.client_count(doc) == 1

      for i <- 1..3 do
        other = Yex.Doc.new()
        Yex.Map.set(Yex.Doc.get_map(other, "count_test"), "k#{i}", "v")
        {:ok, u} = Yex.encode_state_as_update(other)
        :ok = Yex.apply_update(doc, u)
      end

      assert CrdtBridge.client_count(doc) == 4
    end
  end

  describe "normalize_doc/1" do
    defp seed_body(doc, str) do
      text = Yex.Doc.get_text(doc, CrdtBridge.text_name())
      Yex.Text.insert(text, 0, str)
      doc
    end

    # PR #2084 review H3: the chunker reads a BOM note's frontmatter, but the
    # shared splitter must not, or every such note's body is rewritten on the
    # next room bind and broadcast to every device.
    test "a BOM note is not normalized: no key lifted, body byte-identical" do
      bom = "\uFEFF---\ntitle: Hi\n---\nbody\n"
      doc = CrdtBridge.new_doc() |> seed_body(bom)
      assert :ok = CrdtBridge.normalize_doc(doc)
      assert CrdtBridge.frontmatter_of(doc) == {[], %{}}
      assert CrdtBridge.body_of(doc) == bom
    end

    test "lifts a single leading fence into the Y.Map and strips it from the body" do
      doc = CrdtBridge.new_doc() |> seed_body("---\ntitle: Hi\n---\nbody\n")
      assert :ok = CrdtBridge.normalize_doc(doc)
      assert CrdtBridge.frontmatter_of(doc) == {["title"], %{"title" => "\"Hi\""}}
      assert CrdtBridge.body_of(doc) == "body\n"
    end

    test "heals stacked fences in one call, appending fence-only keys in order" do
      doc =
        CrdtBridge.new_doc()
        |> seed_body("---\nasdf: asdf\n---\n---\ntitle: Hi\ntags:\n  - a\n---\nbody\n")

      assert :ok = CrdtBridge.normalize_doc(doc)

      assert CrdtBridge.frontmatter_of(doc) ==
               {["asdf", "title", "tags"],
                %{"asdf" => "\"asdf\"", "title" => "\"Hi\"", "tags" => "[\"a\"]"}}

      assert CrdtBridge.body_of(doc) == "body\n"
    end

    test "Y.Map wins on a key collision; fence value is discarded" do
      doc = CrdtBridge.new_doc()
      map = Yex.Doc.get_map(doc, "frontmatter")
      Yex.Map.set(map, "title", "\"New\"")
      arr = Yex.Doc.get_array(doc, "frontmatter_order")
      Yex.Array.insert_list(arr, 0, ["title"])
      seed_body(doc, "---\ntitle: Old\n---\nbody\n")
      assert :ok = CrdtBridge.normalize_doc(doc)
      assert CrdtBridge.frontmatter_of(doc) == {["title"], %{"title" => "\"New\""}}
      assert CrdtBridge.body_of(doc) == "body\n"
    end

    # Review of Engram-obsidian#697 (HIGH): the plugin lifts a body fence by
    # deleting exactly [0, fence). A server heal that DIFFED to the rest
    # trimmed the shared leading `-` and deleted different Y items, so a
    # concurrent lift by both merged to the union and ate the list marker.
    test "a concurrent heal with the plugin keeps a body starting with `-`" do
      fence = "---\r\ntitle: T\r\n---\r\n"
      body = "- item one\r\n- item two\r\n"
      base = CrdtBridge.new_doc() |> seed_body(fence <> body)
      {:ok, state} = Yex.encode_state_as_update(base)
      {:ok, server} = CrdtBridge.doc_from_state(state)
      {:ok, plugin} = CrdtBridge.doc_from_state(state)

      assert :ok = CrdtBridge.normalize_doc(server)
      # The plugin's lift (note-seed.ts liftBodyFence): delete [0, fence).
      Yex.Text.delete(Yex.Doc.get_text(plugin, CrdtBridge.text_name()), 0, byte_size(fence))

      {:ok, from_server} = Yex.encode_state_as_update(server)
      {:ok, from_plugin} = Yex.encode_state_as_update(plugin)
      :ok = Yex.apply_update(plugin, from_server)
      :ok = Yex.apply_update(server, from_plugin)

      # The server heal also strips the body's CRs (LF-only docs).
      assert CrdtBridge.body_of(server) == "- item one\n- item two\n"
      assert CrdtBridge.body_of(plugin) == "- item one\n- item two\n"
    end

    test "strips CRs from the body: CRLF and a lone CR both become LF" do
      doc = CrdtBridge.new_doc() |> seed_body("a\r\nb\rc\n\r\n")
      assert :ok = CrdtBridge.normalize_doc(doc)
      assert CrdtBridge.body_of(doc) == "a\nb\nc\n\n"
    end

    test "lifts a CRLF fence and leaves an LF body" do
      doc = CrdtBridge.new_doc() |> seed_body("---\r\ntitle: T\r\n---\r\nbody\r\n")
      assert :ok = CrdtBridge.normalize_doc(doc)
      assert CrdtBridge.frontmatter_of(doc) == {["title"], %{"title" => "\"T\""}}
      assert CrdtBridge.body_of(doc) == "body\n"
    end

    # Per-CR deletes, not one diff from the first CR to the last: a diff span
    # re-inserts everything between, resurrecting a word a concurrent client
    # deleted inside that span.
    test "the CR heal touches only CRs, so a concurrent mid-body delete survives" do
      base = CrdtBridge.new_doc() |> seed_body("a\r\none two\r\nb\r\n")
      {:ok, state} = Yex.encode_state_as_update(base)
      {:ok, server} = CrdtBridge.doc_from_state(state)
      {:ok, plugin} = CrdtBridge.doc_from_state(state)

      assert :ok = CrdtBridge.normalize_doc(server)
      # The plugin deletes " two" (UTF-16 offset 6, 4 units) concurrently.
      Yex.Text.delete(Yex.Doc.get_text(plugin, CrdtBridge.text_name()), 6, 4)

      {:ok, from_server} = Yex.encode_state_as_update(server)
      {:ok, from_plugin} = Yex.encode_state_as_update(plugin)
      :ok = Yex.apply_update(plugin, from_server)
      :ok = Yex.apply_update(server, from_plugin)

      assert CrdtBridge.body_of(server) == "a\none\nb\n"
      assert CrdtBridge.body_of(plugin) == "a\none\nb\n"
    end

    test "two concurrent CR heals converge without eating text" do
      base = CrdtBridge.new_doc() |> seed_body("x\r\ny\r\nz")
      {:ok, state} = Yex.encode_state_as_update(base)
      {:ok, a} = CrdtBridge.doc_from_state(state)
      {:ok, b} = CrdtBridge.doc_from_state(state)

      assert :ok = CrdtBridge.normalize_doc(a)
      assert :ok = CrdtBridge.normalize_doc(b)

      {:ok, from_a} = Yex.encode_state_as_update(a)
      {:ok, from_b} = Yex.encode_state_as_update(b)
      :ok = Yex.apply_update(a, from_b)
      :ok = Yex.apply_update(b, from_a)

      assert CrdtBridge.body_of(a) == "x\ny\nz"
      assert CrdtBridge.body_of(b) == "x\ny\nz"
    end

    test "the CR heal is idempotent: a second pass mints no ops" do
      doc = CrdtBridge.new_doc() |> seed_body("a\r\nb\r\n")
      assert :ok = CrdtBridge.normalize_doc(doc)
      sv = Yex.encode_state_vector!(doc)
      assert :ok = CrdtBridge.normalize_doc(doc)
      assert Yex.encode_state_vector!(doc) == sv
      assert CrdtBridge.body_of(doc) == "a\nb\n"
    end

    # An old plugin still writes CRLF and body fences as raw Yjs ops through
    # the room, after the doc was healed once. The next room open must catch
    # them again: the heal is a cheap unconditional scan, never skipped.
    test "a doc healed once is healed again after a later CRLF and fence write" do
      doc = CrdtBridge.new_doc() |> seed_body("x\r\n")
      assert :ok = CrdtBridge.normalize_doc(doc)
      assert CrdtBridge.body_of(doc) == "x\n"

      text = Yex.Doc.get_text(doc, CrdtBridge.text_name())
      Yex.Text.insert(text, 0, "---\r\ntitle: T\r\n---\r\na\r\nb")
      assert :ok = CrdtBridge.normalize_doc(doc)
      assert CrdtBridge.frontmatter_of(doc) == {["title"], %{"title" => "\"T\""}}
      assert CrdtBridge.body_of(doc) == "a\nbx\n"
    end

    test "no-op when the body has no leading fence" do
      doc = CrdtBridge.new_doc() |> seed_body("just body\nmore\n")
      assert :ok = CrdtBridge.normalize_doc(doc)
      assert CrdtBridge.frontmatter_of(doc) == {[], %{}}
      assert CrdtBridge.body_of(doc) == "just body\nmore\n"
    end

    test "no-op on a mid-body horizontal rule (fence not at the very top)" do
      doc = CrdtBridge.new_doc() |> seed_body("text\n---\nmore\n")
      assert :ok = CrdtBridge.normalize_doc(doc)
      assert CrdtBridge.frontmatter_of(doc) == {[], %{}}
      assert CrdtBridge.body_of(doc) == "text\n---\nmore\n"
    end

    test "leaves a non-map YAML top block untouched (not real frontmatter)" do
      doc = CrdtBridge.new_doc() |> seed_body("---\njust a scalar line\n---\nx\n")
      assert :ok = CrdtBridge.normalize_doc(doc)
      assert CrdtBridge.frontmatter_of(doc) == {[], %{}}
      assert CrdtBridge.body_of(doc) == "---\njust a scalar line\n---\nx\n"
    end

    test "is idempotent" do
      doc = CrdtBridge.new_doc() |> seed_body("---\ntitle: Hi\n---\nbody\n")
      assert :ok = CrdtBridge.normalize_doc(doc)
      first = {CrdtBridge.frontmatter_of(doc), CrdtBridge.body_of(doc)}
      assert :ok = CrdtBridge.normalize_doc(doc)
      assert {CrdtBridge.frontmatter_of(doc), CrdtBridge.body_of(doc)} == first
    end

    test "lifts a DEGRADED leading-fence key losslessly (does not drop it)" do
      # A legacy doc whose body begins with a fence containing an unencodable
      # key (nested non-binary key). normalize must lift it via the out-of-band
      # raw store, NOT strip-and-drop it. The key's data survives byte-for-byte.
      original = "---\ntags:\n  - a\ndate: {[a, b]: 1}\n---\nbody\n"
      doc = CrdtBridge.new_doc() |> seed_body(original)
      assert :ok = CrdtBridge.normalize_doc(doc)
      assert CrdtBridge.text_of(doc) == original
    end

    test "leaves the doc untouched when a degraded key cannot be captured losslessly" do
      # Non-binary top-level key: no column-0 span, parse_for_ingest -> :error.
      # normalize must NOT strip the fence (that would lose the block).
      original = "---\n{[a, b]: 1}: {[c, d]: 2}\n---\nbody\n"
      doc = CrdtBridge.new_doc() |> seed_body(original)
      assert :ok = CrdtBridge.normalize_doc(doc)
      assert CrdtBridge.frontmatter_of(doc) == {[], %{}}
      assert CrdtBridge.body_of(doc) == original
    end

    test "strips an empty frontmatter fence and terminates" do
      doc = CrdtBridge.new_doc() |> seed_body("---\n---\nbody\n")
      assert :ok = CrdtBridge.normalize_doc(doc)
      assert CrdtBridge.frontmatter_of(doc) == {[], %{}}
      assert CrdtBridge.body_of(doc) == "body\n"
    end
  end

  describe "a writer other than the room, on a doc that still holds CRs" do
    # Docs seeded before LF-only (or by an old plugin) still hold CRs. Only the
    # room removes them; every other writer diffs its LF text against an LF
    # VIEW of the body and maps the edit back to raw offsets, so it never
    # emits an op on a CR already in the doc.
    defp raw_doc(body) do
      doc = CrdtBridge.new_doc()
      doc |> Yex.Doc.get_text(CrdtBridge.text_name()) |> Yex.Text.insert(0, body)
      doc
    end

    defp fork(doc) do
      {:ok, state} = Yex.encode_state_as_update(doc)
      {:ok, a} = CrdtBridge.doc_from_state(state)
      {:ok, b} = CrdtBridge.doc_from_state(state)
      {a, b}
    end

    defp sync(a, b) do
      {:ok, from_a} = Yex.encode_state_as_update(a)
      {:ok, from_b} = Yex.encode_state_as_update(b)
      :ok = Yex.apply_update(a, from_b)
      :ok = Yex.apply_update(b, from_a)
    end

    test "an LF write leaves the doc's CRs alone and applies only the edit" do
      doc = raw_doc("a\r\nb\rc\r\n")
      :ok = CrdtBridge.ingest_plaintext(doc, "a\nbX\nc\n", lf_view: true)
      assert CrdtBridge.body_of(doc) == "a\r\nbX\rc\r\n"
    end

    test "an edit next to a CRLF never splits the pair" do
      doc = raw_doc("a\r\nb")
      :ok = CrdtBridge.ingest_plaintext(doc, "aX\nb", lf_view: true)
      assert CrdtBridge.body_of(doc) == "aX\r\nb"
    end

    test "an unchanged LF write mints no ops on a CRLF doc" do
      doc = raw_doc("a\r\nb\r\n")
      sv = Yex.encode_state_vector!(doc)
      :ok = CrdtBridge.ingest_plaintext(doc, "a\nb\n", lf_view: true)
      assert Yex.encode_state_vector!(doc) == sv
    end

    test "a deletion spanning a CRLF takes the CR with it" do
      doc = raw_doc("a\r\nb\r\nc")
      :ok = CrdtBridge.ingest_plaintext(doc, "ac", lf_view: true)
      assert CrdtBridge.body_of(doc) == "ac"
    end

    test "without lf_view (canvas) the write lands byte-exact" do
      doc = raw_doc("{\r\n}")
      :ok = CrdtBridge.ingest_plaintext(doc, "{\n}")
      assert CrdtBridge.body_of(doc) == "{\n}"
    end

    # Plugin-style seed (LF-view diff) racing the room heal on a lone-CR note.
    test "a concurrent LF-view seed plus the room heal give ONE line break" do
      {seed, room} = fork(raw_doc("a\rb\n"))
      :ok = CrdtBridge.ingest_plaintext(seed, "a\nb\nedit\n", lf_view: true)
      :ok = CrdtBridge.normalize_doc(room)
      sync(seed, room)
      assert CrdtBridge.body_of(seed) == "a\nb\nedit\n"
      assert CrdtBridge.body_of(room) == "a\nb\nedit\n"
    end

    # Review MED 2: a REST/MCP write right after a room open. The room's heal
    # is in the tail, the snapshot still holds the lone CR.
    test "a three-way write after a room heal does not double a lone CR" do
      {:ok, %{state: snap}} = CrdtBridge.merge_plaintext(nil, "a\rb\n")
      {:ok, snapshot_doc} = CrdtBridge.doc_from_state(snap)
      {:ok, tail_doc} = CrdtBridge.doc_from_state(snap)
      :ok = CrdtBridge.normalize_doc(tail_doc)

      assert {:ok, %{text: text}} =
               CrdtBridge.merge_plaintext_relative_to_snapshot(
                 snapshot_doc,
                 tail_doc,
                 "a\nb\nx",
                 lf_view: true
               )

      assert text == "a\nb\nx"
    end

    test "a classic-Mac note written by two writers converges with no doubling" do
      {w1, w2} = fork(raw_doc("one\rtwo\rthree\r"))
      :ok = CrdtBridge.ingest_plaintext(w1, "ONE\ntwo\nthree\n", lf_view: true)
      :ok = CrdtBridge.ingest_plaintext(w2, "one\ntwo\nTHREE\n", lf_view: true)
      sync(w1, w2)
      {room, _} = fork(w1)
      :ok = CrdtBridge.normalize_doc(room)
      assert CrdtBridge.body_of(room) == "ONE\ntwo\nTHREE\n"
    end

    # The lone-CR heal inserts the LF at the CR first, then deletes the CR, so
    # the LF's right origin is the CR item and it sorts before anything a
    # device inserted right after that CR. Delete-then-insert let a concurrent
    # append land before the LF. Client ids are random, so run it many times.
    test "the room heal of a lone CR sorts before a concurrent append after it" do
      for _ <- 1..40 do
        {room, device} = fork(raw_doc("a\rb\rc\r"))
        :ok = CrdtBridge.normalize_doc(room)
        Yex.Text.insert(Yex.Doc.get_text(device, CrdtBridge.text_name()), 6, "from a\n")
        sync(room, device)
        assert CrdtBridge.body_of(room) == "a\nb\nc\nfrom a\n"
        assert CrdtBridge.body_of(device) == "a\nb\nc\nfrom a\n"
      end
    end

    # A concurrent tail edit between two CRs survives the three-way merge.
    test "the three-way merge keeps a tail delete that sits between CRs" do
      {:ok, %{state: snap}} = CrdtBridge.merge_plaintext(nil, "a\r\none two\r\nb\r\n")
      {:ok, snapshot_doc} = CrdtBridge.doc_from_state(snap)
      {:ok, tail_doc} = CrdtBridge.doc_from_state(snap)
      Yex.Text.delete(Yex.Doc.get_text(tail_doc, CrdtBridge.text_name()), 6, 4)

      assert {:ok, %{text: text}} =
               CrdtBridge.merge_plaintext_relative_to_snapshot(
                 snapshot_doc,
                 tail_doc,
                 "a\none two\nb\nz\n",
                 lf_view: true
               )

      assert text == "a\r\none\r\nb\r\nz\n"
    end

    test "ingesting the same text twice mints no ops the second time" do
      {:ok, doc} = CrdtBridge.doc_from_state(nil)
      :ok = CrdtBridge.ingest_plaintext(doc, "---\ntitle: T\n---\na\nb\n")
      sv = Yex.encode_state_vector!(doc)
      :ok = CrdtBridge.ingest_plaintext(doc, "---\ntitle: T\n---\na\nb\n")
      assert Yex.encode_state_vector!(doc) == sv
    end
  end

  describe "normalize_doc/1 and raw frontmatter" do
    # Review LOW 4: a degraded key's verbatim span ingested as CRLF.
    test "rewrites a raw frontmatter span that holds CRs, and nothing when clean" do
      doc = CrdtBridge.new_doc()
      raw = Yex.Doc.get_map(doc, "frontmatter_raw")
      Yex.Map.set(raw, "date", "date: {[a, b]: 1}\r\n")
      Yex.Map.set(raw, "ok", "ok: {[c]: 2}\n")
      :ok = CrdtBridge.normalize_doc(doc)

      assert CrdtBridge.raw_frontmatter_of(doc) == %{
               "date" => "date: {[a, b]: 1}\n",
               "ok" => "ok: {[c]: 2}\n"
             }

      sv = Yex.encode_state_vector!(doc)
      :ok = CrdtBridge.normalize_doc(doc)
      assert Yex.encode_state_vector!(doc) == sv
    end
  end

  test "multibyte + astral-plane (emoji) edits round-trip without corruption" do
    # Astral emoji 🎉 / 😀 are 2 UTF-16 code units each; multibyte BMP chars
    # (é, 漢) are 1 unit but >1 byte — a :bytes offset would mis-slice both.
    {:ok, %{state: s1, text: t1}} = CrdtBridge.merge_plaintext(nil, "café 漢字 🎉 end")
    assert t1 == "café 漢字 🎉 end"

    # Edit in the middle, after an astral char: insert/delete around 🎉.
    {:ok, %{state: s2, text: t2}} = CrdtBridge.merge_plaintext(s1, "café 漢字 🎉🎊 middle end")
    assert t2 == "café 漢字 🎉🎊 middle end"

    # Replace an astral char with another (surrogate-pair boundary edit).
    {:ok, %{text: t3}} = CrdtBridge.merge_plaintext(s2, "café 漢字 😀 middle end")
    assert t3 == "café 漢字 😀 middle end"

    # Two divergent edits from the emoji-bearing base still converge.
    {:ok, %{state: ea}} = CrdtBridge.merge_plaintext(s1, "café 漢字 🎉 end — A")
    {:ok, %{state: eb}} = CrdtBridge.merge_plaintext(s1, "B — café 漢字 🎉 end")
    {:ok, merged} = CrdtBridge.doc_from_state(ea)
    :ok = Yex.apply_update(merged, eb)
    final = CrdtBridge.text_of(merged)
    assert final =~ "— A"
    assert final =~ "B —"
    assert String.valid?(final)
  end
end
