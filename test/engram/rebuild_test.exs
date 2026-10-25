defmodule Engram.RebuildTest do
  @moduledoc """
  The v5 rebuild switch, manifest and ledger (plan Task 16.1).

  async: false: swaps the global `:keyword_index` adapter and runs the
  reconcile cron, which reads global Oban state.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Mox

  alias Engram.Crypto
  alias Engram.DataMigrations
  alias Engram.DataMigrations.IndexVersions
  alias Engram.Indexing
  alias Engram.KeywordIndex
  alias Engram.Notes
  alias Engram.Notes.Note
  alias Engram.Parsers.Markdown
  alias Engram.Rebuild
  alias Engram.ServiceConfig
  alias Engram.Workers.{RebuildDryRun, RebuildStaleNote, ReconcileEmbeddings}

  setup :set_mox_global
  setup :verify_on_exit!

  # A "stamp bump" in a test build: the build stays at chunker 3 / keyword 2
  # and the pins drop to 2 / 1, so a note stamped 2 / 1 is behind the build
  # but not behind what `off` rebuilds.
  @pins {Markdown.chunker_version() - 1, KeywordIndex.version() - 1}

  setup do
    DataMigrations.reset_cache()
    Engram.Cache.clear_local(:rebuild)
    Repo.query!("DELETE FROM rebuild_ledger")
    :ok
  end

  # `on` and the seal need the v5 write layout (Task 16.4).
  defp mode!(mode) do
    ServiceConfig.put_override(:write_v5_layout, true)
    ServiceConfig.put_override(:index_rebuild, mode)
  end

  defp bumped_note(attrs \\ []) do
    user = insert(:user)

    insert(
      :note,
      Keyword.merge(
        [
          user: user,
          vault: insert(:vault, user: user),
          content_hash: "abc123",
          embed_hash: "abc123",
          dense_indexed_hash: "abc123",
          chunker_version: elem(@pins, 0),
          keyword_version: elem(@pins, 1)
        ],
        attrs
      )
    )
  end

  # #2199: a pass that kept points in place must not stamp past them.
  describe "pass_stamp/2" do
    test "off: a reused pass keeps a behind keyword stamp, stamps the chunker" do
      {chunker, keyword} = Rebuild.target_versions()
      behind = %{chunker_version: chunker - 1, keyword_version: keyword - 1}

      assert Rebuild.pass_stamp(behind, true) == {chunker, keyword - 1}
      assert Rebuild.pass_stamp(behind, false) == {chunker, keyword}

      assert Rebuild.pass_stamp(%{chunker_version: nil, keyword_version: nil}, true) ==
               {chunker, nil}
    end

    test "on: a reused pass keeps both behind stamps for the rebuild" do
      Rebuild.set_budget(10)
      mode!("on")
      {chunker, keyword} = Rebuild.target_versions()
      behind = %{chunker_version: chunker - 1, keyword_version: keyword - 1}

      assert Rebuild.pass_stamp(behind, true) == {chunker - 1, keyword - 1}
      assert Rebuild.pass_stamp(behind, false) == {chunker, keyword}
      at = %{chunker_version: chunker, keyword_version: keyword}
      assert Rebuild.pass_stamp(at, true) == {chunker, keyword}
    end
  end

  describe "mode/0" do
    test "defaults to :off and reads dry_run / on" do
      assert Rebuild.mode() == :off
      mode!("dry_run")
      assert Rebuild.mode() == :dry_run
      Rebuild.set_budget(10)
      mode!("on")
      assert Rebuild.mode() == :on
    end

    test "an unknown value is :off" do
      mode!("yes please")
      assert Rebuild.mode() == :off
    end
  end

  describe "the version term is gated on the switch" do
    setup do
      ServiceConfig.put_override(:rebuild_pinned_versions, @pins)
      :ok
    end

    test "off enqueues no rebuilds after a stamp bump" do
      note = bumped_note()

      assert :ok = perform_job(ReconcileEmbeddings, %{})

      refute_enqueued(worker: RebuildStaleNote, args: %{"note_id" => note.id})
      refute_enqueued(worker: RebuildDryRun)
    end

    test "off with a bump queues no rebuild for a keyword-stale note (nil or below the pin)" do
      missing = bumped_note(keyword_version: nil)
      below = bumped_note(keyword_version: elem(@pins, 1) - 1)

      assert :ok = perform_job(ReconcileEmbeddings, %{})

      for note <- [missing, below] do
        refute_enqueued(worker: RebuildStaleNote, args: %{"note_id" => note.id})
        refute Engram.Workers.EmbedNote.version_stale?(note)
      end
    end

    test "off with the build at its pins is today's sweep: an older stamp still rebuilds" do
      ServiceConfig.put_override(
        :rebuild_pinned_versions,
        {Markdown.chunker_version(), KeywordIndex.version()}
      )

      note = bumped_note()

      assert :ok = perform_job(ReconcileEmbeddings, %{})
      assert_enqueued(worker: RebuildStaleNote, args: %{"note_id" => note.id})
    end

    test "dry_run enqueues the dry run and no rebuilds" do
      note = bumped_note()
      mode!("dry_run")

      assert :ok = perform_job(ReconcileEmbeddings, %{})

      refute_enqueued(worker: RebuildStaleNote, args: %{"note_id" => note.id})
      assert_enqueued(worker: RebuildDryRun)
    end

    test "on rebuilds the bumped note" do
      note = bumped_note()
      Rebuild.set_budget(1_000)
      mode!("on")

      assert :ok = perform_job(ReconcileEmbeddings, %{})
      assert_enqueued(worker: RebuildStaleNote, args: %{"note_id" => note.id})
    end

    test "resuming on after off continues from the per-note stamps" do
      # `rebuilt` was done by the pass before it was switched off.
      rebuilt =
        bumped_note(
          chunker_version: Markdown.chunker_version(),
          keyword_version: KeywordIndex.version()
        )

      pending = bumped_note()

      assert :ok = perform_job(ReconcileEmbeddings, %{})
      refute_enqueued(worker: RebuildStaleNote)

      Rebuild.set_budget(1_000)
      mode!("on")
      assert :ok = perform_job(ReconcileEmbeddings, %{})

      assert_enqueued(worker: RebuildStaleNote, args: %{"note_id" => pending.id})
      refute_enqueued(worker: RebuildStaleNote, args: %{"note_id" => rebuilt.id})
    end

    test "the data migration name follows the gate, so on reopens it" do
      off_name = IndexVersions.name()
      assert off_name =~ "chunker=#{elem(@pins, 0)},keyword=#{elem(@pins, 1)},"

      Rebuild.set_budget(1)
      mode!("on")

      assert IndexVersions.name() =~
               "chunker=#{Markdown.chunker_version()},keyword=#{KeywordIndex.version()},"
    end
  end

  describe "dry run" do
    setup do
      ServiceConfig.put_override(:rebuild_pinned_versions, @pins)
      test_pid = self()
      bypass = Bypass.open()
      ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

      # Fails on ANY Qdrant call, read or write: the dry run plans locally.
      Bypass.stub(bypass, :any, :any, fn conn ->
        send(test_pid, {:qdrant_call, conn.method, conn.request_path})
        Plug.Conn.send_resp(conn, 500, "dry run must not call Qdrant")
      end)

      # No Mox expectation: any embed call raises Mox.UnexpectedCallError.
      expect(Engram.MockEmbedder, :embed_texts, 0, fn _ -> flunk("Voyage called") end)

      {:ok, user} = Crypto.ensure_user_dek(insert(:user))
      vault = insert(:vault, user: user)
      %{user: user, vault: vault}
    end

    defp stale_note!(user, vault, path, content) do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{"path" => path, "content" => content, "mtime" => 1.0},
          actor: "api"
        )

      Repo.with_tenant!(user.id, fn ->
        from(n in Note, where: n.id == ^note.id)
        |> Repo.update_all(
          set: [
            embed_hash: note.content_hash,
            dense_indexed_hash: note.content_hash,
            chunker_version: elem(@pins, 0),
            keyword_version: elem(@pins, 1)
          ]
        )
      end)

      note
    end

    defp manifest(user_id) do
      Repo.with_tenant!(user_id, fn ->
        from(m in "rebuild_manifest",
          select: %{
            note_id: type(m.note_id, Ecto.UUID),
            est_tokens: m.est_tokens,
            new_points: m.new_points,
            reused_points: m.reused_points,
            mean_pooled_points: m.mean_pooled_points,
            planned?: not is_nil(m.planned_at)
          }
        )
        |> Repo.all()
      end)
    end

    # The real flow: the coordinator queues planners, they run, and the next
    # coordinator run seals.
    defp dry_run! do
      assert :ok = perform_job(RebuildDryRun, %{})
      Oban.drain_queue(queue: :events)
      assert :ok = perform_job(RebuildDryRun, %{})
    end

    defp planner_jobs(user),
      do: all_enqueued(worker: RebuildDryRun, args: %{"user_id" => user.id})

    test "writes manifest rows, vault avgdl and the budget with 0 Voyage and 0 Qdrant calls",
         %{user: user, vault: vault} do
      a = stale_note!(user, vault, "A.md", "# Alpha\n\n" <> String.duplicate("alpha words ", 200))
      b = stale_note!(user, vault, "B.md", "# Beta\n\n" <> String.duplicate("beta words ", 300))
      mode!("dry_run")

      dry_run!()

      rows = manifest(user.id)
      assert Enum.map(rows, & &1.note_id) |> Enum.sort() == Enum.sort([a.id, b.id])
      assert Enum.all?(rows, &(&1.est_tokens > 0 and &1.new_points > 0))

      assert Rebuild.pinned_avgdl(user.id, vault.id) > 0.0

      sum = rows |> Enum.map(& &1.est_tokens) |> Enum.sum()

      assert Rebuild.ledger() == %{
               budget_tokens: div(115 * sum + 99, 100),
               spent_tokens: 0,
               halted?: false
             }

      refute_received {:qdrant_call, _, _}
    end

    test "the coordinator queues one planner per user and does not seal before they finish",
         %{user: user, vault: vault} do
      _ = stale_note!(user, vault, "A.md", "# Alpha\n\nsome words here")
      mode!("dry_run")

      assert :ok = perform_job(RebuildDryRun, %{})
      assert [_one] = planner_jobs(user)
      assert Rebuild.ledger() == nil

      # A second coordinator run while the planner is pending queues nothing
      # more and still does not seal.
      assert :ok = perform_job(RebuildDryRun, %{})
      assert [_one] = planner_jobs(user)
      assert Rebuild.ledger() == nil
    end

    test "a completed user is not planned again", %{user: user, vault: vault} do
      _ = stale_note!(user, vault, "A.md", "# Alpha\n\nsome words here")
      mode!("dry_run")
      dry_run!()
      Repo.query!("DELETE FROM rebuild_ledger")

      assert :ok = perform_job(RebuildDryRun, %{})
      refute Enum.any?(planner_jobs(user), &(&1.state == "available"))
    end

    test "a planner re-run skips notes already in the manifest", %{user: user, vault: vault} do
      _ = stale_note!(user, vault, "A.md", "# Alpha\n\nsome words here")
      mode!("dry_run")
      assert :ok = perform_job(RebuildDryRun, %{"user_id" => user.id})
      [before] = manifest(user.id)

      assert :ok = perform_job(RebuildDryRun, %{"user_id" => user.id})
      assert manifest(user.id) == [before]
    end

    test "a planner cancels once the mode leaves dry_run", %{user: user, vault: vault} do
      _ = stale_note!(user, vault, "A.md", "# Alpha\n\nsome words here")
      mode!("on")

      assert {:cancel, :not_dry_run} = perform_job(RebuildDryRun, %{"user_id" => user.id})
      assert manifest(user.id) == []
    end

    test "the coordinator is a no-op unless the mode is dry_run", %{user: user, vault: vault} do
      _ = stale_note!(user, vault, "A.md", "# Alpha\n\nsome words here")

      assert :ok = perform_job(RebuildDryRun, %{})
      assert planner_jobs(user) == []
      assert Rebuild.ledger() == nil
    end

    test "a note whose planning crashed (dead-man row left pending) is never planned again",
         %{user: user, vault: vault} do
      crashed = stale_note!(user, vault, "A.md", "# Alpha\n\nsome words here")
      ok = stale_note!(user, vault, "B.md", "# Beta\n\nother words here")
      :ok = Rebuild.put_pending(user.id, crashed)
      mode!("dry_run")

      assert :ok = perform_job(RebuildDryRun, %{"user_id" => user.id})

      by_id = Map.new(manifest(user.id), &{&1.note_id, &1})
      assert %{est_tokens: 0, planned?: false} = by_id[crashed.id]
      assert %{planned?: true} = by_id[ok.id]
      assert by_id[ok.id].est_tokens > 0
    end

    test "a note the embed crash guard charged a death to is skipped", %{user: user, vault: vault} do
      note = stale_note!(user, vault, "A.md", "# Alpha\n\nsome words here")

      Repo.with_tenant!(user.id, fn ->
        Repo.update_all(from(n in Note, where: n.id == ^note.id), set: [embed_crashes: 1])
      end)

      mode!("dry_run")
      assert :ok = perform_job(RebuildDryRun, %{"user_id" => user.id})
      assert manifest(user.id) == []
    end
  end

  describe "seal/0" do
    setup do
      user = insert(:user)
      vault = insert(:vault, user: user)
      %{user: user, vault: vault}
    end

    defp planned!(user, vault, est, dl_sum) do
      note = insert(:note, user: user, vault: vault)

      :ok =
        Rebuild.put_manifest(user.id, [
          %{
            note_id: note.id,
            vault_id: vault.id,
            est_tokens: est,
            new_points: 1,
            reused_points: 0,
            mean_pooled_points: 0,
            dl_sum: dl_sum,
            dl_count: 1
          }
        ])
    end

    test "seals only while the mode is still dry_run", %{user: user, vault: vault} do
      planned!(user, vault, 100, 10)
      mode!("on")

      assert Rebuild.seal() == {:error, :not_dry_run}
      assert Rebuild.ledger() == nil
      assert Rebuild.pinned_avgdl(user.id, vault.id) == nil
    end

    test "never clears a halt and never overwrites a budget already set",
         %{user: user, vault: vault} do
      planned!(user, vault, 1_000_000, 10)
      Rebuild.set_budget(5)
      assert Rebuild.debit(10) == :halt
      mode!("dry_run")

      assert Rebuild.seal() == {:ok, 5}
      assert Rebuild.ledger() == %{budget_tokens: 5, spent_tokens: 10, halted?: true}
    end

    test "never replaces a pin once a budget is sealed", %{user: user, vault: vault} do
      mode!("dry_run")
      planned!(user, vault, 100, 10)
      assert {:ok, _} = Rebuild.seal()
      Engram.Cache.clear_local(:rebuild)
      assert Rebuild.pinned_avgdl(user.id, vault.id) == 10.0

      # A late row would move the vault's average to 20.
      planned!(user, vault, 100, 30)
      assert {:ok, _} = Rebuild.seal()
      Engram.Cache.clear_local(:rebuild)
      assert Rebuild.pinned_avgdl(user.id, vault.id) == 10.0
    end
  end

  describe "rebuild_estimate/2 on indexed notes" do
    import Engram.IndexBudgetHelpers

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
      %{user: user, vault: vault}
    end

    @pad String.duplicate("filler words here ", 30)

    defp sections(n),
      do: Enum.map_join(1..n, "\n\n", &"## Section #{&1}\n\nBody #{&1}. #{@pad}")

    defp indexed!(user, vault, content) do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{"path" => "N.md", "content" => content, "mtime" => 1.0},
          actor: "api"
        )

      assert {:ok, count} = Indexing.index_note(note, vault, user)
      assert count >= 4
      %{note | dense_indexed_hash: note.content_hash}
    end

    defp estimate!(note, user) do
      {:ok, decrypted} = Crypto.maybe_decrypt_note_fields(note, user)

      {:ok, est} =
        Repo.with_tenant!(user.id, fn -> Indexing.rebuild_estimate(decrypted, user) end)

      est
    end

    test "an unchanged indexed note reuses every point for 0 tokens", %{user: user, vault: vault} do
      note = indexed!(user, vault, sections(4))
      est = estimate!(note, user)

      assert est.reused_points >= 4
      assert est.new_points == 0
      assert est.est_tokens == 0
    end

    test "a capped note whose members each have a stored vector is mean-pooled for 0 tokens",
         %{user: user, vault: vault} do
      note = indexed!(user, vault, sections(6))
      enable_index_budget()
      insert(:user_limit_override, user: user, key: "note_points_cap", value: %{"v" => 2})

      est = estimate!(note, Repo.reload!(user, skip_tenant_check: true))

      assert est.mean_pooled_points > 0
      assert est.est_tokens == 0
    end

    # A note that never got dense vectors (a spent cap left it sparse-only)
    # has no stored vector to average: its merged groups are paid for.
    test "a capped sparse-only note is never counted as mean-pooled", %{user: user, vault: vault} do
      note = %{indexed!(user, vault, sections(6)) | dense_indexed_hash: nil}
      enable_index_budget()
      insert(:user_limit_override, user: user, key: "note_points_cap", value: %{"v" => 2})

      est = estimate!(note, Repo.reload!(user, skip_tenant_check: true))

      assert est.mean_pooled_points == 0
      assert est.est_tokens > 0
    end

    test "a note with no dense hash is planned dense and estimated with tokens",
         %{user: user, vault: vault} do
      {:ok, note} =
        Notes.upsert_note(
          user,
          vault,
          %{"path" => "N.md", "content" => sections(4), "mtime" => 1.0},
          actor: "api"
        )

      assert note.dense_indexed_hash == nil
      assert Indexing.version_rebuild_opts(note)[:maintenance] == false
      assert estimate!(note, user).est_tokens > 0
    end
  end

  describe "debit/1" do
    test "past 1.15x of the manifest returns :halt, and the mode reads :off" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :rebuild, :halted]])
      Rebuild.set_budget(1_000)
      mode!("on")

      assert Rebuild.debit(600) == :ok
      assert Rebuild.debit(400) == :ok
      assert Rebuild.mode() == :on

      assert Rebuild.debit(1) == :halt
      assert_received {[:engram, :rebuild, :halted], ^ref, %{count: 1, spent_tokens: 1_001}, _}
      assert Rebuild.mode() == :off
      assert Rebuild.ledger() == %{budget_tokens: 1_000, spent_tokens: 1_001, halted?: true}

      # Halted stays halted, nothing is spent past it unrecorded, and the
      # halt event (the PromEx counter) fires once per off transition.
      assert Rebuild.debit(1) == :halt
      refute_received {[:engram, :rebuild, :halted], ^ref, _, _}
    end

    test "the halt is a PromEx counter" do
      %{metrics: metrics} = Engram.PromEx.Indexing.event_metrics(otp_app: :engram)
      assert Enum.any?(metrics, &(&1.event_name == [:engram, :rebuild, :halted]))
    end

    test "with no ledger (no dry run sealed a budget) halts" do
      mode!("on")
      assert Rebuild.debit(1) == :halt
      assert Rebuild.mode() == :off
    end

    test "a new budget clears the halt" do
      Rebuild.set_budget(1)
      assert Rebuild.debit(2) == :halt
      Rebuild.set_budget(10)
      mode!("on")
      assert Rebuild.mode() == :on
      assert Rebuild.debit(1) == :ok
    end
  end

  describe "check_note/2" do
    setup do
      user = insert(:user)
      %{user: user, vault: insert(:vault, user: user)}
    end

    defp est!(user, vault, est) do
      note = insert(:note, user: user, vault: vault)

      :ok =
        Rebuild.put_manifest(user.id, [
          %{
            note_id: note.id,
            vault_id: vault.id,
            est_tokens: est,
            new_points: 1,
            reused_points: 0,
            mean_pooled_points: 0,
            dl_sum: 10,
            dl_count: 1
          }
        ])

      note
    end

    test "parks past 1.5x the estimate and 50k tokens", %{user: user, vault: vault} do
      note = est!(user, vault, 40_000)
      assert Rebuild.check_note(note, 60_000) == :ok
      assert Rebuild.check_note(note, 60_001) == {:park, :rebuild_drift}
    end

    test "never parks at or under 50k tokens", %{user: user, vault: vault} do
      note = est!(user, vault, 1_000)
      assert Rebuild.check_note(note, 50_000) == :ok
      assert Rebuild.check_note(note, 50_001) == {:park, :rebuild_drift}
    end

    test "a note with no estimate counts as 0", %{user: user, vault: vault} do
      note = insert(:note, user: user, vault: vault)
      assert Rebuild.check_note(note, 50_000) == :ok
      assert Rebuild.check_note(note, 50_001) == {:park, :rebuild_drift}
    end
  end

  describe "H14 pinned avgdl" do
    defmodule RecordingKeywordIndex do
      @moduledoc false
      @behaviour Engram.KeywordIndex

      alias Engram.KeywordIndex.QdrantSparse

      @impl true
      def encode_documents(texts, filter_key, avgdl, language) do
        send(self(), {:avgdl, avgdl})
        QdrantSparse.encode_documents(texts, filter_key, avgdl, language)
      end

      @impl true
      def encode_query(query, filter_key, language),
        do: QdrantSparse.encode_query(query, filter_key, language)
    end

    setup do
      bypass = Bypass.open()
      ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

      Bypass.stub(bypass, :any, :any, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": true, "status": "ok"}))
      end)

      Application.put_env(:engram, :keyword_index, RecordingKeywordIndex)
      on_exit(fn -> Application.delete_env(:engram, :keyword_index) end)

      stub(Engram.MockEmbedder, :embed_texts, fn texts ->
        {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
      end)

      {:ok, user} = Crypto.ensure_user_dek(insert(:user))
      %{user: user, vault: insert(:vault, user: user)}
    end

    defp index!(user, vault, path, content) do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{"path" => path, "content" => content, "mtime" => 1.0},
          actor: "api"
        )

      assert {:ok, _} = Indexing.index_note(note, vault, user)
      assert_received {:avgdl, avgdl}
      avgdl
    end

    defp pin!(user, vault, avgdl) do
      Repo.with_tenant!(user.id, fn ->
        Repo.insert_all("rebuild_manifest_vaults", [
          %{vault_id: Ecto.UUID.dump!(vault.id), user_id: Ecto.UUID.dump!(user.id), avgdl: avgdl}
        ])
      end)
    end

    test "two notes indexed at pass start and end use the same pinned avgdl", ctx do
      %{user: user, vault: vault} = ctx
      pin!(user, vault, 42.0)
      Rebuild.set_budget(1_000)
      mode!("on")

      first = index!(user, vault, "Start.md", "# Start\n\nshort")
      # Between them the vault's live avgdl moves a lot.
      Engram.Cache.clear_local(:avgdl)
      _ = index!(user, vault, "Mid.md", "# Mid\n\n" <> String.duplicate("long words ", 400))
      Engram.Cache.clear_local(:avgdl)
      last = index!(user, vault, "End.md", "# End\n\nshort again")

      assert first == 42.0
      assert last == 42.0
    end

    test "off reads the live avgdl, not the pin", %{user: user, vault: vault} do
      pin!(user, vault, 42.0)
      refute index!(user, vault, "A.md", "# A\n\nwords") == 42.0
    end
  end
end
