defmodule Engram.NotesCrdtOriginGateTest do
  # Pure gate logic — no DB. The gate decides whether a CRDT-origin rename
  # (relocate via genesis_crdt_note) enqueues the server-side link rewrite.
  use ExUnit.Case, async: true

  alias Engram.Notes

  test "obsidian-tagged renames NEVER enqueue (Obsidian rewrites its own links)" do
    refute Notes.crdt_rename_rewrites?("obsidian")
  end

  test "web-tagged renames enqueue exactly via the gate" do
    assert Notes.crdt_rename_rewrites?("web")
  end

  test "a PRESENT-but-unknown tag enqueues (spec safe default — not a skewed plugin)" do
    assert Notes.crdt_rename_rewrites?("mobile")
  end

  test "untagged (nil) takes the flip flag — currently plugin-origin, NO enqueue" do
    # TEMPORARY COMPROMISE PIN (#648 Phase 2): version-skewed plugins that
    # predate the client_type join tag must not double-rewrite, so untagged
    # defaults to "obsidian" until the tagged plugin release has been out one
    # release cycle. The flip (this assertion changing to "web" / assert) is a
    # ONE-LINE change to @untagged_crdt_client_type in Engram.Notes. If this
    # test fails because the flag flipped, update BOTH asserts below together.
    assert Notes.untagged_crdt_client_type() == "obsidian"
    refute Notes.crdt_rename_rewrites?(nil)
  end
end
