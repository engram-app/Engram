defmodule Engram.Workers.EmbedNoteTxnCountTest do
  # Budget: tenant transactions per EmbedNote job. Each one is three round
  # trips (BEGIN, tenant_enter, COMMIT), and in prod this worker ran ~9 of them
  # per job. The pre-embed reads share one, the post-embed writes another.
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Mox

  alias Engram.Notes
  alias Engram.Repo
  alias Engram.TenantQueryCounter
  alias Engram.Workers.EmbedNote

  setup :verify_on_exit!

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    Bypass.expect(bypass, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": {"status": "ok"}, "status": "ok"}))
    end)

    user = insert(:user)
    vault = insert(:vault, user: user)

    {:ok, note} =
      Notes.upsert_note(
        user,
        vault,
        %{"path" => "Perf/Txn.md", "content" => "# Txn\n\nCount them.", "mtime" => 1_000.0},
        actor: "api"
      )

    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    %{user: user, vault: vault, note: note, bypass: bypass}
  end

  test "a full EmbedNote job opens at most 5 tenant transactions",
       %{user: user, vault: vault, note: note} do
    # avgdl is cached per vault (10 min), so a steady stream of jobs reads it
    # once per vault, not once per job. Warm it so the budget counts per-job
    # transactions only.
    _ = Engram.KeywordIndex.Stats.avgdl(user.id, vault.id)

    enters =
      TenantQueryCounter.count_tenant_enters(fn ->
        assert :ok = perform_job(EmbedNote, %{note_id: note.id, user_id: user.id})
      end)

    # Reads (note, user, vault), crash-guard stamp, chunk plan (the vector
    # cache lookup rides it), the vector cache write for the one Voyage batch
    # (`VectorCache.put_many/5`, committed as the batch returns so a retry
    # pays nothing), then the chunk write carrying the hash stamp and the
    # crash-guard clear. Was 9.
    assert length(enters) <= 5,
           "EmbedNote opened #{length(enters)} tenant transactions, budget is 5"

    note = Repo.reload!(note, skip_tenant_check: true)
    assert note.embed_hash == note.content_hash
    assert is_nil(note.embed_started_at), "the success path must clear the crash-guard stamp"
  end

  test "an empty note stamps and clears in one transaction after the purge",
       %{user: user, vault: vault, note: note, bypass: bypass} do
    # Nothing to index, so Qdrant is reached only if stale points exist.
    Bypass.pass(bypass)

    {:ok, note} =
      Notes.upsert_note(
        user,
        vault,
        %{"path" => note.path, "content" => "", "mtime" => 2_000.0},
        actor: "api"
      )

    enters =
      TenantQueryCounter.count_tenant_enters(fn ->
        assert :ok = perform_job(EmbedNote, %{note_id: note.id, user_id: user.id})
      end)

    assert length(enters) <= 4,
           "EmbedNote opened #{length(enters)} tenant transactions, budget is 4"

    note = Repo.reload!(note, skip_tenant_check: true)
    assert note.embed_hash == note.content_hash
    assert is_nil(note.embed_started_at)
  end
end
