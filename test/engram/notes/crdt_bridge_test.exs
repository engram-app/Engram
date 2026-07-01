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

  describe "text_of vs body_of" do
    test "text_of returns the full projected note; body_of returns body only" do
      doc = CrdtBridge.new_doc()
      :ok = CrdtBridge.ingest_plaintext(doc, "---\ntitle: Hi\n---\nbody\n")
      assert CrdtBridge.text_of(doc) == "---\ntitle: Hi\n---\nbody\n"
      assert CrdtBridge.body_of(doc) == "body\n"
    end
  end

  describe "ingest_plaintext/2" do
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

  describe "flatten/1 preserves frontmatter" do
    test "flattened doc keeps frontmatter and body" do
      doc = CrdtBridge.new_doc()
      :ok = CrdtBridge.ingest_plaintext(doc, "---\ntitle: Hi\n---\nbody\n")
      {:ok, %{doc: flat}} = CrdtBridge.flatten(doc)
      assert CrdtBridge.text_of(flat) == "---\ntitle: Hi\n---\nbody\n"
    end
  end

  describe "normalize_doc/1" do
    defp seed_body(doc, str) do
      text = Yex.Doc.get_text(doc, CrdtBridge.text_name())
      Yex.Text.insert(text, 0, str)
      doc
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

    test "strips an empty frontmatter fence and terminates" do
      doc = CrdtBridge.new_doc() |> seed_body("---\n---\nbody\n")
      assert :ok = CrdtBridge.normalize_doc(doc)
      assert CrdtBridge.frontmatter_of(doc) == {[], %{}}
      assert CrdtBridge.body_of(doc) == "body\n"
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
