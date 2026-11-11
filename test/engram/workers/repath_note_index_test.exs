defmodule Engram.Workers.RepathNoteIndexTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Workers.{EmbedNote, RefreshKeywordVectors, RepathNoteIndex}

  # R3a: a rename makes no Qdrant call. A job an older node queued still
  # runs on this one (rolling deploy) and must succeed doing nothing: an
  # unexpected request to the Bypass Qdrant fails the test.
  test "a queued job (plain or bulk) succeeds with no Qdrant call and no follow-up job" do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user)
    note = Engram.Fixtures.insert_note!(user, vault, %{path: "New/Hello.md", content: "# Hi"})
    args = %{note_id: note.id, user_id: user.id, old_path_hmac: Base.encode64(<<7>>)}

    assert :ok = perform_job(RepathNoteIndex, args)
    assert :ok = perform_job(RepathNoteIndex, Map.put(args, :bulk, true))

    refute_enqueued(worker: RefreshKeywordVectors)
    refute_enqueued(worker: EmbedNote)
  end
end
