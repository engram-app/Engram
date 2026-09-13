defmodule Engram.Workers.ReindexKeywordTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Notes.Chunk
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Workers.{EmbedNote, ReindexKeyword}

  defp insert_chunk!(note, hmac) do
    Repo.insert!(
      %Chunk{
        note_id: note.id,
        user_id: note.user_id,
        vault_id: note.vault_id,
        position: 0,
        char_start: 0,
        char_end: 10,
        qdrant_point_id: Ecto.UUID.generate(),
        context_hmac: hmac
      },
      skip_tenant_check: true
    )
  end

  test "enqueues a per-vault re-normalize job" do
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)

    assert :ok = ReindexKeyword.enqueue(vault.id)
    assert_enqueued(worker: ReindexKeyword, args: %{"vault_id" => vault.id})
  end

  test "perform/1 re-enqueues all vault notes through EmbedNote" do
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)
    note_a = insert(:note, user: user, vault: vault)
    note_b = insert(:note, user: user, vault: vault)

    assert :ok = perform_job(ReindexKeyword, %{"vault_id" => to_string(vault.id)})

    assert_enqueued(worker: EmbedNote, args: %{"note_id" => note_a.id})
    assert_enqueued(worker: EmbedNote, args: %{"note_id" => note_b.id})
  end

  # #1477 — re-enqueuing was never enough. `EmbedNote` short-circuits on
  # `embed_hash == content_hash`, which is every note a re-normalizer targets;
  # and since #1595 even a note that DOES run reuses each point whose
  # `context_hmac` still matches, keeping the stale BM25 weight and
  # `token_count` verbatim (`indexing.ex:763` — "no embed, no tokenizer pass").
  # Both have to be cleared or the re-normalize is a silent no-op.
  test "perform/1 clears reuse markers and index hashes so the rebuild is real" do
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)

    note =
      insert(:note,
        user: user,
        vault: vault,
        content_hash: "same",
        embed_hash: "same",
        dense_indexed_hash: "same"
      )

    chunk = insert_chunk!(note, "reuse-me")

    assert :ok = perform_job(ReindexKeyword, %{"vault_id" => to_string(vault.id)})

    assert is_nil(Repo.get!(Chunk, chunk.id, skip_tenant_check: true).context_hmac)

    reloaded = Repo.get!(Note, note.id, skip_tenant_check: true)
    assert is_nil(reloaded.embed_hash)
    assert is_nil(reloaded.dense_indexed_hash)

    assert_enqueued(worker: EmbedNote, args: %{"note_id" => note.id})
  end

  test "perform/1 touches only the target vault" do
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    target = insert(:vault, user: user)
    other = insert(:vault, user: user)

    target_note =
      insert(:note,
        user: user,
        vault: target,
        content_hash: "a",
        embed_hash: "a",
        dense_indexed_hash: "a"
      )

    target_chunk = insert_chunk!(target_note, "flag-me")

    bystander =
      insert(:note,
        user: user,
        vault: other,
        content_hash: "b",
        embed_hash: "b",
        dense_indexed_hash: "b"
      )

    bystander_chunk = insert_chunk!(bystander, "keep-me")

    assert :ok = perform_job(ReindexKeyword, %{"vault_id" => to_string(target.id)})

    # Both halves, or this passes on a build that writes nothing at all: the
    # target MUST be flagged...
    assert is_nil(Repo.get!(Chunk, target_chunk.id, skip_tenant_check: true).context_hmac)
    flagged = Repo.get!(Note, target_note.id, skip_tenant_check: true)
    assert is_nil(flagged.embed_hash)
    assert is_nil(flagged.dense_indexed_hash)

    # ...and a bulk UPDATE that forgot its vault scope would re-embed every
    # vault this user owns, the exact blast radius this worker must bound.
    assert Repo.get!(Chunk, bystander_chunk.id, skip_tenant_check: true).context_hmac == "keep-me"

    kept = Repo.get!(Note, bystander.id, skip_tenant_check: true)
    assert kept.embed_hash == "b"
    assert kept.dense_indexed_hash == "b"
  end

  test "perform/1 leaves soft-deleted notes untouched" do
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)

    deleted =
      insert(:note,
        user: user,
        vault: vault,
        content_hash: "d",
        embed_hash: "d",
        dense_indexed_hash: "d",
        deleted_at: DateTime.utc_now(:microsecond)
      )

    deleted_chunk = insert_chunk!(deleted, "gone")

    assert :ok = perform_job(ReindexKeyword, %{"vault_id" => to_string(vault.id)})

    # The select excludes them, so the UPDATEs must too — a soft-deleted note's
    # points are already removed, so flagging it buys a rebuild with nothing to
    # rebuild.
    assert Repo.get!(Chunk, deleted_chunk.id, skip_tenant_check: true).context_hmac == "gone"

    still = Repo.get!(Note, deleted.id, skip_tenant_check: true)
    assert still.embed_hash == "d"
    assert still.dense_indexed_hash == "d"

    refute_enqueued(worker: EmbedNote, args: %{"note_id" => deleted.id})
  end

  test "perform/1 is a no-op when vault has no notes" do
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)

    assert :ok = perform_job(ReindexKeyword, %{"vault_id" => to_string(vault.id)})
    refute_enqueued(worker: EmbedNote)
  end

  test "perform/1 excludes folder marker rows (kind='folder')" do
    insert(:user_limit_override, user: build(:user), key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Test", Ecto.UUID.generate())

    note = insert(:note, user: user, vault: vault)
    {:ok, marker} = Engram.Notes.create_folder_marker(user, vault, "Docs")

    assert marker.kind == "folder"

    assert :ok = perform_job(ReindexKeyword, %{"vault_id" => to_string(vault.id)})

    assert_enqueued(worker: EmbedNote, args: %{"note_id" => note.id})
    refute_enqueued(worker: EmbedNote, args: %{"note_id" => marker.id})
  end
end
