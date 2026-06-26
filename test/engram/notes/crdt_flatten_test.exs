defmodule Engram.Notes.CrdtFlattenTest do
  use ExUnit.Case, async: true

  alias Engram.Notes.CrdtBridge

  # Build a doc that crosses the client-ID threshold (>= 1000 distinct clients).
  # Each Yex.Doc.new() gets a random client_id; merging 1200 of them into one
  # doc gives us 1200+ entries in the state vector.
  defp bloated_doc do
    {:ok, %{state: s}} = CrdtBridge.merge_plaintext(nil, "real content here")
    {:ok, doc} = CrdtBridge.doc_from_state(s)

    for _ <- 1..1200 do
      edit = Yex.Doc.new()
      t = Yex.Doc.get_text(edit, CrdtBridge.text_name())
      Yex.Text.insert(t, 0, "x")
      {:ok, u} = Yex.encode_state_as_update(edit)
      :ok = Yex.apply_update(doc, u)
    end

    doc
  end

  # Build a doc whose state is large in bytes but has only a few client-IDs.
  defp large_single_author_doc do
    # ~600 KB of content from one author (many edits to same doc)
    {:ok, %{state: s}} = CrdtBridge.merge_plaintext(nil, String.duplicate("a", 600_000))
    {:ok, doc} = CrdtBridge.doc_from_state(s)
    doc
  end

  # Build a doc with many client-IDs but tiny content.
  defp small_many_client_doc do
    {:ok, %{state: s}} = CrdtBridge.merge_plaintext(nil, "tiny")
    {:ok, doc} = CrdtBridge.doc_from_state(s)

    for _ <- 1..1200 do
      edit = Yex.Doc.new()
      t = Yex.Doc.get_text(edit, CrdtBridge.text_name())
      Yex.Text.insert(t, 0, "x")
      {:ok, u} = Yex.encode_state_as_update(edit)
      :ok = Yex.apply_update(doc, u)
    end

    doc
  end

  test "client_count returns distinct client-ID count from state vector" do
    {:ok, %{state: s}} = CrdtBridge.merge_plaintext(nil, "hello")
    {:ok, doc} = CrdtBridge.doc_from_state(s)
    # Just the two clients (seed doc + doc_from_state creates a new one, but
    # the state applied brings in the seed's client); count >= 1.
    assert CrdtBridge.client_count(doc) >= 1
  end

  test "should_flatten? requires BOTH byte-size AND client-count thresholds (AND, not OR)" do
    # Case (b): large bytes, few clients — must NOT flatten
    large_doc = large_single_author_doc()
    {:ok, large_state} = Yex.encode_state_as_update(large_doc)
    assert byte_size(large_state) >= 500_000
    assert CrdtBridge.client_count(large_doc) < 1000
    refute CrdtBridge.should_flatten?(large_state, large_doc)

    # Case (c): many clients, small bytes — must NOT flatten
    small_doc = small_many_client_doc()
    {:ok, small_state} = Yex.encode_state_as_update(small_doc)
    assert CrdtBridge.client_count(small_doc) >= 1000
    assert byte_size(small_state) < 500_000
    refute CrdtBridge.should_flatten?(small_state, small_doc)
  end

  test "flatten preserves text but resets client-ID bloat" do
    doc = bloated_doc()
    before_text = CrdtBridge.text_of(doc)

    # Case (a): BOTH thresholds — but we need to also pad the byte size.
    # The bloated doc has 1200+ clients; the state encodes client-ID entries
    # for each. Let's check if it already crosses 500 KB; if not, the test
    # still validates the flatten mechanism when called directly.
    assert CrdtBridge.client_count(doc) >= 1000

    # Case (d): content preserved after flatten
    {:ok, %{doc: flat, state: flat_state}} = CrdtBridge.flatten(doc)
    assert CrdtBridge.text_of(flat) == before_text
    # Flattened doc has exactly 1 client-ID (from new_doc/0)
    assert CrdtBridge.client_count(flat) == 1
    assert byte_size(flat_state) > 0
  end

  test "flatten result state re-decodes to the same text" do
    doc = bloated_doc()
    before_text = CrdtBridge.text_of(doc)

    {:ok, %{state: flat_state}} = CrdtBridge.flatten(doc)
    {:ok, reloaded} = CrdtBridge.doc_from_state(flat_state)
    assert CrdtBridge.text_of(reloaded) == before_text
  end

  test "should_flatten? is true when BOTH thresholds are crossed" do
    # Build a doc that exceeds BOTH thresholds: 1200 clients + large-enough state.
    # We'll merge 1200 client docs that each insert 500 bytes so the total state
    # is large too.
    {:ok, %{state: s}} = CrdtBridge.merge_plaintext(nil, "seed content")
    {:ok, doc} = CrdtBridge.doc_from_state(s)

    for _ <- 1..1200 do
      edit = Yex.Doc.new()
      t = Yex.Doc.get_text(edit, CrdtBridge.text_name())
      # Insert ~420 bytes per client so total state easily exceeds 500 KB
      Yex.Text.insert(t, 0, String.duplicate("x", 420))
      {:ok, u} = Yex.encode_state_as_update(edit)
      :ok = Yex.apply_update(doc, u)
    end

    {:ok, state} = Yex.encode_state_as_update(doc)
    assert byte_size(state) >= 500_000, "expected state >= 500KB, got #{byte_size(state)}"
    assert CrdtBridge.client_count(doc) >= 1000
    assert CrdtBridge.should_flatten?(state, doc)
  end
end
