defmodule Engram.DataMigrations.IndexVersionsPinTest do
  @moduledoc """
  Prod deploy safety for the v5 stamp (chunker v5 plan, Task 17.1).

  The build moves to chunker 5 / keyword 5 while prod notes carry 3 / 2.
  Until an operator sets `INDEX_REBUILD=on`, every version check targets the
  pins, so the deploy makes no note version-stale: nothing re-embeds and
  Voyage spend is $0. `test_helper.exs` pins the suite to the build's
  versions, so every test here installs the REAL pins
  (`Rebuild.pinned_versions/0`) itself.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Mox

  alias Engram.Crypto
  alias Engram.DataMigrations
  alias Engram.DataMigrations.IndexVersions
  alias Engram.Notes.Note
  alias Engram.Rebuild
  alias Engram.ServiceConfig
  alias Engram.Workers.{EmbedNote, RebuildStaleNote, ReconcileEmbeddings, RefreshKeywordVectors}

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    DataMigrations.reset_cache()
    Engram.Cache.clear_local(:rebuild)
    Repo.query!("DELETE FROM rebuild_ledger")
    ServiceConfig.put_override(:rebuild_pinned_versions, Rebuild.pinned_versions())
    :ok
  end

  defp mode!(mode), do: ServiceConfig.put_override(:index_rebuild, mode)

  defp complete!(name), do: DataMigrations.mark_done(name, IndexVersions.version())

  defp stamped_note(chunker, keyword) do
    user = insert(:user)

    insert(:note,
      user: user,
      vault: insert(:vault, user: user),
      content_hash: "abc123",
      embed_hash: "abc123",
      dense_indexed_hash: "abc123",
      embed_model: Engram.Indexing.embed_model(),
      chunker_version: chunker,
      keyword_version: keyword
    )
  end

  test "the build is v5: chunker 5, keyword 5" do
    assert Rebuild.build_versions() == {5, 5}
  end

  test "the pins equal prod's pre-v5 stamps: chunker 3, keyword 2" do
    assert Rebuild.pinned_versions() == {3, 2}
  end

  test "no config file sets the pins, so prod runs on the real ones" do
    for file <- Path.wildcard("config/*.exs") do
      refute File.read!(file) =~ "rebuild_pinned_versions", "#{file} sets the rebuild pins"
    end
  end

  for mode <- ["off", "dry_run"] do
    test "#{mode}: the target is the pins and no prod note is version-stale" do
      mode!(unquote(mode))

      assert Rebuild.target_versions() == {3, 2}
      assert IndexVersions.name() =~ "index_versions:chunker=3,keyword=2,"

      # Prod's stamps, and a note a newer release stamped (H10: `<`, not `!=`).
      notes = [stamped_note(3, 2), stamped_note(5, 4)]
      for note <- notes, do: refute(EmbedNote.version_stale?(note))

      # Any Voyage call fails the test.
      expect(Engram.MockEmbedder, :embed_texts, 0, fn _ -> flunk("Voyage called") end)

      assert :ok = perform_job(ReconcileEmbeddings, %{})

      for note <- notes, worker <- [EmbedNote, RebuildStaleNote, RefreshKeywordVectors] do
        refute_enqueued(worker: worker, args: %{"note_id" => note.id})
      end
    end
  end

  describe "after the build's pass completed, off is the steady state" do
    # Prod, 2026-11-01: the ledger closed the v5 pass. `off` then targets the
    # build, so an edit is stamped with the versions its points really hold.
    for mode <- ["off", "dry_run"] do
      test "#{mode}: the target is the build once its ledger row is complete" do
        complete!("index_versions:chunker=5,keyword=5,model=voyage-4-large")
        mode!(unquote(mode))

        assert Rebuild.target_versions() == {5, 5}
        assert IndexVersions.name() =~ "index_versions:chunker=5,keyword=5,"
        assert EmbedNote.version_stale?(stamped_note(3, 2))
        refute EmbedNote.version_stale?(stamped_note(5, 5))
      end
    end

    test "any embed model's completed row counts: the model has its own term" do
      complete!("index_versions:chunker=5,keyword=5,model=some-older-model")
      mode!("off")

      assert Rebuild.target_versions() == {5, 5}
    end

    # Self-host on old data: only the pre-v5 row (or none) is complete. The
    # pins hold, so its {3, 2} notes stay current and nothing re-embeds.
    test "off without a completed v5 pass keeps the pins, so old data stays current" do
      complete!("index_versions:chunker=3,keyword=2,model=voyage-4-large")
      DataMigrations.note_open("index_versions:chunker=5,keyword=5,model=voyage-4-large", 1)
      mode!("off")

      assert Rebuild.target_versions() == {3, 2}
      note = stamped_note(3, 2)
      refute EmbedNote.version_stale?(note)

      expect(Engram.MockEmbedder, :embed_texts, 0, fn _ -> flunk("Voyage called") end)
      assert :ok = perform_job(ReconcileEmbeddings, %{})

      for worker <- [EmbedNote, RebuildStaleNote, RefreshKeywordVectors] do
        refute_enqueued(worker: worker, args: %{"note_id" => note.id})
      end
    end
  end

  describe "newest_completed/1" do
    test "the next bump keeps the last completed pass, not the pins" do
      complete!("index_versions:chunker=3,keyword=2,model=voyage-4-large")
      complete!("index_versions:chunker=5,keyword=5,model=voyage-4-large")
      DataMigrations.note_open("index_versions:chunker=6,keyword=6,model=voyage-4-large", 1)

      assert IndexVersions.newest_completed({6, 6}) == {5, 5}
    end

    test "capped at the build, nil when nothing completed" do
      assert IndexVersions.newest_completed({5, 5}) == nil
      complete!("index_versions:chunker=5,keyword=5,model=voyage-4-large")
      assert IndexVersions.newest_completed({4, 4}) == {4, 4}
    end

    test "off: a completed 5/4 pass targets 5/4 (never below it, never the pins)" do
      complete!("index_versions:chunker=3,keyword=2,model=voyage-4-large")
      complete!("index_versions:chunker=5,keyword=4,model=voyage-4-large")
      mode!("off")

      assert Rebuild.target_versions() == {5, 4}
    end
  end

  test "on targets the build: chunker 5, keyword 5" do
    Rebuild.set_budget(1_000)
    mode!("on")

    assert Rebuild.target_versions() == {5, 5}

    assert IndexVersions.name() ==
             "index_versions:chunker=5,keyword=5,model=#{Engram.Indexing.embed_model() || "none"}"

    assert EmbedNote.version_stale?(stamped_note(3, 2))
  end

  describe "an edit before the pass is stamped with the target, not the build" do
    setup do
      bypass = Bypass.open()
      ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

      Bypass.stub(bypass, :any, :any, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": true, "status": "ok"}))
      end)

      stub(Engram.MockEmbedder, :embed_texts, fn texts ->
        {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
      end)

      {:ok, user} = Crypto.ensure_user_dek(insert(:user))
      vault = insert(:vault, user: user)

      note =
        Engram.Fixtures.insert_note!(user, vault, %{
          path: "Pin/Edited.md",
          content: "# Edited\n\nWritten before the v5 pass."
        })

      %{note: note}
    end

    # Stamping the build (5 / 3) here would make the pass skip a note whose
    # points are not in its layout or encoding; the pin keeps it in the pass.
    for mode <- ["off", "dry_run"] do
      test "#{mode}: EmbedNote stamps 3 / 2", %{note: note} do
        mode!(unquote(mode))

        assert :ok = perform_job(EmbedNote, %{note_id: note.id})

        reloaded = Repo.get!(Note, note.id, skip_tenant_check: true)
        assert reloaded.embed_hash == reloaded.content_hash
        assert {reloaded.chunker_version, reloaded.keyword_version} == {3, 2}
      end
    end

    test "off after the pass completed: EmbedNote stamps the build, 5 / 5", %{note: note} do
      complete!("index_versions:chunker=5,keyword=5,model=voyage-4-large")
      mode!("off")

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      reloaded = Repo.get!(Note, note.id, skip_tenant_check: true)
      assert reloaded.embed_hash == reloaded.content_hash
      assert {reloaded.chunker_version, reloaded.keyword_version} == {5, 5}
    end
  end
end
