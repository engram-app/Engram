defmodule Engram.Workers.ReconcileBackstopTest do
  @moduledoc """
  R6: `ReconcileEmbeddings` is a backstop that runs every 3 hours. It chains
  itself (a successor in 5 minutes) only while work only it can do remains:
  an open `IndexVersions` rollout, or the daily re-verify with a full page.
  It counts what it finds (`[:engram, :reconcile, :found]`), and `missed`
  marks a content change no event queued. Per-note Qdrant work is never
  queued into a shut Qdrant gate, where it would only snooze.

  async: false: the Qdrant gate verdict and pressure are node-wide.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query

  alias Engram.DataMigrations
  alias Engram.DataMigrations.IndexVersions
  alias Engram.KeywordIndex
  alias Engram.Parsers.Markdown
  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant
  alias Engram.Workers.{EmbedNote, RebuildStaleNote, ReconcileEmbeddings, RefreshKeywordVectors}

  @found [:engram, :reconcile, :found]

  setup do
    DataMigrations.reset_cache()
    Application.put_env(:engram, :embed_model, "test-embed-model")
    on_exit(fn -> Application.delete_env(:engram, :embed_model) end)
  end

  defp note_for(user, attrs) do
    defaults = [
      user: user,
      vault: insert(:vault, user: user),
      chunker_version: Markdown.chunker_version(),
      keyword_version: KeywordIndex.version(),
      embed_model: "test-embed-model"
    ]

    insert(:note, Keyword.merge(defaults, attrs))
  end

  # Indexed at its current content, at the current versions.
  defp current_note(user, attrs) do
    note_for(
      user,
      Keyword.merge(
        [
          content_hash: "abc123",
          embed_hash: "abc123",
          dense_indexed_hash: "abc123",
          chunker_version: Markdown.chunker_version(),
          embed_model: "test-embed-model",
          keyword_version: KeywordIndex.version()
        ],
        attrs
      )
    )
  end

  defp close_rollout, do: :ok = DataMigrations.mark_done(IndexVersions.name(), 1)

  defp successors do
    Repo.all(
      from(j in Oban.Job,
        where: j.worker == ^inspect(ReconcileEmbeddings) and j.state == "scheduled"
      )
    )
  end

  defp assert_in_five_minutes(%Oban.Job{scheduled_at: at}),
    do: assert(DateTime.diff(at, DateTime.utc_now()) in 290..300)

  describe "the cron table" do
    test "the backstop runs every 3 hours and the re-verify once a day, on :02" do
      crontab = Engram.Test.ObanWorkers.crontab()
      assert {"2 */3 * * *", ReconcileEmbeddings} in crontab

      entries = for {expr, ReconcileEmbeddings} <- crontab, do: expr
      assert Enum.sort(entries) == ["2 */3 * * *", "2 4 * * *"]

      {_, _, opts} =
        Enum.find(cron_entries(), &match?({"2 4 * * *", ReconcileEmbeddings, _}, &1))

      assert opts[:args] == %{"mode" => "reverify"}
    end
  end

  defp cron_entries do
    :engram
    |> Application.get_env(Oban)
    |> Keyword.fetch!(:plugins)
    |> Enum.find_value(fn
      {Oban.Plugins.Cron, opts} -> Keyword.fetch!(opts, :crontab)
      _ -> nil
    end)
  end

  describe "chaining while work remains" do
    test "an open rollout queues its successor in 5 minutes; a closed one queues none" do
      assert :ok = perform_job(ReconcileEmbeddings, %{})
      assert [next] = successors()
      assert next.args == %{}
      assert_in_five_minutes(next)

      Repo.delete_all(Oban.Job)
      close_rollout()
      assert :ok = perform_job(ReconcileEmbeddings, %{})
      assert successors() == []
    end

    test "the re-verify stops when nothing is left" do
      close_rollout()
      assert :ok = perform_job(ReconcileEmbeddings, %{"mode" => "reverify"})
      assert successors() == []
    end

    test "the re-verify hops on while a page comes back full, up to 12 runs" do
      close_rollout()
      ServiceConfig.put_override(:keyword_refresh_backlog, 1)
      user = insert(:user)
      for _ <- 1..2, do: current_note(user, keyword_version: nil)

      assert :ok = perform_job(ReconcileEmbeddings, %{"mode" => "reverify"})
      assert [next] = successors()
      assert next.args == %{"mode" => "reverify", "hop" => 1}
      assert_in_five_minutes(next)

      Repo.delete_all(from(j in Oban.Job, where: j.worker == ^inspect(ReconcileEmbeddings)))
      assert :ok = perform_job(ReconcileEmbeddings, %{"mode" => "reverify", "hop" => 11})
      assert successors() == []
    end

    test "a kick pulls a scheduled successor forward instead of queueing a second sweep" do
      assert :ok = perform_job(ReconcileEmbeddings, %{})
      assert [_] = successors()

      {:ok, _} = ReconcileEmbeddings.kick()

      assert [job] =
               Repo.all(from(j in Oban.Job, where: j.worker == ^inspect(ReconcileEmbeddings)))

      assert DateTime.diff(job.scheduled_at, DateTime.utc_now()) <= 1
      assert job.meta["kick"] == true
    end
  end

  describe "the found counter" do
    setup do
      close_rollout()
      ref = :telemetry_test.attach_event_handlers(self(), [@found])
      %{ref: ref}
    end

    defp found(ref) do
      receive do
        {@found, ^ref, %{count: n}, %{reason: reason, missed: missed}} ->
          [{reason, missed, n} | found(ref)]
      after
        0 -> []
      end
    end

    defp hour_ago, do: DateTime.add(DateTime.utc_now(), -3_600, :second)

    test "a stale note no event queued counts as missed", %{ref: ref} do
      user = insert(:user)
      note_for(user, content_hash: "new", embed_hash: "old", updated_at: hour_ago())

      assert :ok = perform_job(ReconcileEmbeddings, %{})
      assert {:content_stale, true, 1} in found(ref)
    end

    test "a note edited seconds ago, its job pending, is not missed", %{ref: ref} do
      user = insert(:user)
      note = note_for(user, content_hash: "new", embed_hash: "old")
      {:ok, _} = Oban.insert(EmbedNote.new_debounced(note.id, user.id))

      assert :ok = perform_job(ReconcileEmbeddings, %{})
      refute Enum.any?(found(ref), &match?({_, true, _}, &1))
    end

    test "a note edited seconds ago with no job is not missed yet (inside the debounce)",
         %{ref: ref} do
      user = insert(:user)
      note_for(user, content_hash: "new", embed_hash: "old")

      assert :ok = perform_job(ReconcileEmbeddings, %{})
      assert {:content_stale, false, 1} in found(ref)
    end

    test "a version rebuild is expected work, never missed", %{ref: ref} do
      user = insert(:user)
      insert(:subscription, user: user, tier: "pro", status: "active")
      current_note(user, chunker_version: nil, keyword_version: nil, updated_at: hour_ago())

      assert :ok = perform_job(ReconcileEmbeddings, %{"mode" => "reverify"})
      assert {:version, false, 1} in found(ref)
    end

    test "what a kick finds is explained by the kick", %{ref: ref} do
      user = insert(:user)
      note_for(user, content_hash: "new", embed_hash: "old", updated_at: hour_ago())

      assert :ok = perform_job(ReconcileEmbeddings, %{}, meta: %{"kick" => true})
      assert {:content_stale, false, 1} in found(ref)
    end
  end

  # The qdrant-disk lane (2026-10-30): 1,424,485 snoozes in 24 h, every one
  # from the Qdrant pace gate, on per-note jobs a sweep had queued into it.
  describe "the Qdrant gate" do
    @green %{"status" => "green", "optimizer_status" => "ok", "update_queue" => %{"length" => 0}}

    setup do
      Application.put_env(:engram, :reconcile_qdrant_gate, true)
      on_exit(fn -> Application.put_env(:engram, :reconcile_qdrant_gate, false) end)
      Engram.Cache.clear_local(:rebuild)
      on_exit(fn -> Engram.Cache.clear_local(:rebuild) end)
      bypass = Bypass.open()
      ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
      Qdrant.forget_pressure()
      on_exit(&Qdrant.forget_pressure/0)
      {:ok, info} = Agent.start_link(fn -> @green end)
      col = "/collections/#{Qdrant.collection_name()}"

      Bypass.stub(bypass, :any, :any, fn conn ->
        body =
          case {conn.method, conn.request_path} do
            {"GET", ^col} ->
              %{"result" => Agent.get(info, & &1), "status" => "ok"}

            {"GET", path} when path == col <> "/optimizations" ->
              %{"result" => %{"summary" => %{"queued_points" => 0}}}

            _ ->
              %{"result" => true, "status" => "ok"}
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end)

      user = insert(:user)
      insert(:subscription, user: user, tier: "pro", status: "active")
      version = current_note(user, chunker_version: nil, keyword_version: nil)
      keyword = current_note(user, keyword_version: nil)
      %{info: info, version: version, keyword: keyword}
    end

    defp per_note_jobs,
      do: all_enqueued(worker: RebuildStaleNote) ++ all_enqueued(worker: RefreshKeywordVectors)

    defp snoozed_jobs,
      do: Repo.all(from(j in Oban.Job, where: fragment("? \\? 'snoozed'", j.meta)))

    test "shut: the sweep queues no per-note Qdrant job and asks again in 5 minutes",
         %{info: info} do
      Agent.update(info, &%{&1 | "status" => "yellow"})

      assert :ok = perform_job(ReconcileEmbeddings, %{})

      assert per_note_jobs() == []
      assert snoozed_jobs() == []
      assert [next] = successors()
      assert_in_five_minutes(next)
    end

    test "shut: the re-verify queues nothing and hops on", %{info: info} do
      close_rollout()
      Agent.update(info, &%{&1 | "status" => "yellow"})

      assert :ok = perform_job(ReconcileEmbeddings, %{"mode" => "reverify"})

      assert per_note_jobs() == []
      assert [%{args: %{"mode" => "reverify", "hop" => 1}}] = successors()
    end

    test "open: the rebuild and the keyword top-up are queued", ctx do
      assert :ok = perform_job(ReconcileEmbeddings, %{})

      assert_enqueued(worker: RebuildStaleNote, args: %{"note_id" => ctx.version.id})
      assert_enqueued(worker: RefreshKeywordVectors, args: %{"note_id" => ctx.keyword.id})
    end
  end
end
