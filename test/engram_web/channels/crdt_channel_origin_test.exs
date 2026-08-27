defmodule EngramWeb.CrdtChannelOriginTest do
  # Phase 2 (#648): client_type join tag → origin-gated RewriteNoteLinks
  # enqueue on the crdt_create relocate (rename) path.
  use EngramWeb.ChannelCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.{Crypto, Notes, Vaults}
  alias Engram.Notes.CrdtBridge
  alias Engram.Repo
  alias Engram.Workers.RewriteNoteLinks

  setup do
    EngramWeb.RateLimiter.reset_buckets!()
    on_exit(fn -> EngramWeb.RateLimiter.reset_buckets!() end)

    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "CrdtOriginTest", Ecto.UUID.generate())
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "Old.md", "content" => "# t"})
    %{user: user, vault: vault, note: note}
  end

  defp join!(user, vault, params) do
    {:ok, _, joined} =
      subscribe_and_join(
        user_socket(user),
        EngramWeb.CrdtChannel,
        "crdt:#{user.id}:#{vault.id}",
        params
      )

    Sandbox.allow(Repo, self(), joined.channel_pid)
    joined
  end

  defp relocate!(socket, note) do
    ref = push(socket, "crdt_create", %{"doc_id" => note.id, "path" => "Fresh.md"})
    assert_reply ref, :ok, %{doc_id: _}
  end

  # Mirrors crdt_channel_test.exs's frame_for_content/1 — a genesis
  # sync_update frame carrying real content, so the roomless seed has a body
  # to apply and reports `genesis: "stored"` rather than declining.
  defp frame_for_content(content) do
    doc = CrdtBridge.new_doc()
    :ok = CrdtBridge.ingest_plaintext(doc, content)
    {:ok, update} = Yex.encode_state_as_update(doc)
    {:ok, frame} = Yex.Sync.message_encode({:sync, {:sync_update, update}})
    Base.encode64(frame)
  end

  test "web-tagged join: relocate enqueues exactly one rewrite job",
       %{user: user, vault: vault, note: note} do
    socket = join!(user, vault, %{"crdt_proto" => 2, "client_type" => "web"})
    relocate!(socket, note)

    assert [job] = all_enqueued(worker: RewriteNoteLinks)
    assert job.args["target_id"] == note.id
    assert {:ok, _} = Base.decode64(job.args["old_path_ciphertext"])
  end

  test "obsidian-tagged join: relocate enqueues nothing",
       %{user: user, vault: vault, note: note} do
    socket = join!(user, vault, %{"crdt_proto" => 2, "client_type" => "obsidian"})
    relocate!(socket, note)
    assert all_enqueued(worker: RewriteNoteLinks) == []
  end

  test "untagged join: relocate enqueues — spec safe default",
       %{user: user, vault: vault, note: note} do
    # Flipped with Notes.untagged_crdt_client_type/0 -> "web" in #1301. Was
    # pinned to "enqueues nothing" while pre-1.20.0 plugins (which predate the
    # client_type join param) were the majority and had to be assumed to be the
    # sole rewriter. Untagged now means "a non-Obsidian client that didn't say",
    # which must get the server rewrite. Obsidian opts out explicitly above.
    socket = join!(user, vault, %{"crdt_proto" => 2})
    relocate!(socket, note)
    assert [job] = all_enqueued(worker: RewriteNoteLinks)
    assert job.args["target_id"] == note.id
  end

  test "genesis-with-content relocate carries the same origin",
       %{user: user, vault: vault, note: note} do
    socket = join!(user, vault, %{"crdt_proto" => 2, "client_type" => "web"})

    # note.id already exists (setup, path "Old.md") — reusing it at a new, free
    # path takes the relocate leg (genesis_relocate_live) rather than a plain
    # genesis. Sent WITH a b64 body on purpose: the seeding path is a separate
    # leg from the bare create above, and origin has to thread through it too.
    ref =
      push(socket, "crdt_create", %{
        "doc_id" => note.id,
        "path" => "Fresh.md",
        "b64" => frame_for_content("body")
      })

    # Assert `genesis`, not just a bare `doc_id`. A reply of `%{doc_id: _}` is
    # byte-identical to the no-b64 create above, so it would pass even if the
    # server ignored the frame outright — which is exactly the leg this covers.
    #
    # `occupied`, NOT `stored`, and that is the correct answer rather than a
    # tolerated one: a relocate moves a row that already holds a body, so
    # `fold_row_and_tail` reads non-empty and `seed_against/7` declines. A
    # `stored` here would mean the frame overwrote the note being renamed.
    assert_reply ref, :ok, %{doc_id: id, genesis: "occupied"}

    # RewriteNoteLinks is what proves the RELOCATE leg specifically: a plain
    # genesis enqueues RebindNoteLinks (notes.ex:1523), only
    # genesis_relocate_live enqueues a rewrite (notes.ex:1362).
    assert [_job] = all_enqueued(worker: RewriteNoteLinks)

    # The relocated body survived the declined seed — the point of declining.
    {:ok, stored} = Notes.get_note_by_id(user, vault, id)
    assert stored.content == "# t"
    assert stored.path == "Fresh.md"
  end
end
