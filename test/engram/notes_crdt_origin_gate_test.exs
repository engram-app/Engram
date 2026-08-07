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

  test "untagged (nil) takes the spec safe default — server-origin, DOES enqueue" do
    # FLIPPED 2026-08-07 (#1301). Was pinned to "obsidian" while plugins
    # predating the client_type join tag (< 1.20.0) were the majority — an
    # untagged socket had to be assumed plugin-origin so Obsidian stayed the
    # sole rewriter. Now that the tagged release has circulated, untagged means
    # "some non-Obsidian client that didn't say" (old web build, future mobile),
    # which must get the server rewrite or its links silently rot. Obsidian opts
    # out explicitly by tagging itself — see the "obsidian" case above.
    assert Notes.untagged_crdt_client_type() == "web"
    assert Notes.crdt_rename_rewrites?(nil)
  end
end
