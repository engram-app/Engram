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
  # sync_update frame carrying real content, so crdt_create_batch's phase-1
  # genesis leg resolves "ok" instead of some other status.
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

  test "batch-path relocate carries the same origin",
       %{user: user, vault: vault, note: note} do
    socket = join!(user, vault, %{"crdt_proto" => 2, "client_type" => "web"})

    # note.id already exists (setup, path "Old.md") — reusing it at a new,
    # free path through crdt_create_batch takes the SAME relocate leg
    # (genesis_relocate_live) that crdt_create does, exercising
    # prepare_create/4's origin threading rather than a plain genesis.
    ref =
      push(socket, "crdt_create_batch", %{
        "creates" => [
          %{"doc_id" => note.id, "path" => "Fresh.md", "b64" => frame_for_content("body")}
        ]
      })

    assert_reply ref, :ok, %{results: [%{status: "ok"}]}
    assert [_job] = all_enqueued(worker: RewriteNoteLinks)
  end
end
