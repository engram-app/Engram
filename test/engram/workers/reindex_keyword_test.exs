defmodule Engram.Workers.ReindexKeywordTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Workers.{EmbedNote, ReindexKeyword}

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

  test "perform/1 is a no-op when vault has no notes" do
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)

    assert :ok = perform_job(ReindexKeyword, %{"vault_id" => to_string(vault.id)})
    refute_enqueued(worker: EmbedNote)
  end
end
