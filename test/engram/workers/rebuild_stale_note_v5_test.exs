defmodule Engram.Workers.RebuildStaleNoteV5Test do
  @moduledoc """
  The v5 pass's own lane (chunker v5 plan, Task 16.2): the `rebuild` queue,
  the 150k tokens/min maintenance bucket, the Qdrant optimizer gate, the
  user order (paid, active Free, inactive Free, whales) and no billable
  Voyage retries (H6).

  async: false: global Mox mode, the shared limiter table, and the
  `:embedder` app env in the H6 test.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Mox

  alias Engram.Crypto
  alias Engram.KeywordIndex
  alias Engram.Notes
  alias Engram.Notes.Note
  alias Engram.Parsers.Markdown
  alias Engram.Rebuild
  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant
  alias Engram.Workers.{RebuildStaleNote, ReconcileEmbeddings}

  setup :set_mox_global
  setup :verify_on_exit!

  @pins {Markdown.chunker_version() - 1, KeywordIndex.version() - 1}

  @green %{"status" => "green", "optimizer_status" => "ok", "update_queue" => %{"length" => 0}}

  setup do
    Engram.Cache.clear_local(:rebuild)
    Repo.query!("DELETE FROM rebuild_ledger")
    EngramWeb.RateLimiter.reset_buckets!()
    ServiceConfig.put_override(:rebuild_pinned_versions, @pins)
    ServiceConfig.put_override(:write_v5_layout, true)
    ServiceConfig.put_override(:index_rebuild, "on")
    Rebuild.set_budget(10_000_000)

    {:ok, health} = Agent.start_link(fn -> {@green, 0} end)
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    stub_qdrant(bypass, health)

    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)
    %{user: user, vault: vault, health: health, bypass: bypass}
  end

  # Collection info and `/optimizations` answer from `health`; every other
  # call (upserts, deletes, scrolls) succeeds.
  defp stub_qdrant(bypass, health) do
    col = "/collections/#{Qdrant.collection_name()}"

    Bypass.stub(bypass, :any, :any, fn conn ->
      {info, queued} = Agent.get(health, & &1)

      body =
        case {conn.method, conn.request_path} do
          {"GET", ^col} -> %{"result" => info, "status" => "ok"}
          {"GET", path} when path == col <> "/optimizations" -> optimizations(queued)
          _ -> %{"result" => true, "status" => "ok"}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end)
  end

  defp optimizations(queued) do
    summary = %{
      "queued_optimizations" => 0,
      "queued_segments" => 0,
      "queued_points" => queued,
      "idle_segments" => 1
    }

    %{"result" => %{"summary" => summary, "running" => []}, "status" => "ok"}
  end

  defp stale_note!(user, vault, path) do
    {:ok, note} =
      Notes.upsert_note(
        user,
        vault,
        %{"path" => path, "content" => "# #{path}\n\nwords for #{path}", "mtime" => 1.0},
        actor: "api"
      )

    Repo.with_tenant!(user.id, fn ->
      Repo.update_all(from(n in Note, where: n.id == ^note.id),
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

  defp rebuild(note),
    do: perform_job(RebuildStaleNote, %{"note_id" => note.id, "user_id" => note.user_id})

  # A Voyage stand-in reporting `tokens` per call, as the real client does.
  defp embedder_reporting(tokens) do
    me = self()

    stub(Engram.MockEmbedder, :embed_texts, fn texts, opts ->
      send(me, {:voyage, opts})

      :telemetry.execute(
        [:engram, :voyage, :embed, :tokens],
        %{total_tokens: tokens},
        %{purpose: opts[:purpose]}
      )

      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)
  end

  test "jobs land on the rebuild queue, not embed", %{user: user, vault: vault} do
    assert RebuildStaleNote.new(%{note_id: Ecto.UUID.generate()}).changes.queue == "rebuild"
    assert Application.fetch_env!(:engram, Oban)[:queues][:rebuild] == 2

    note = stale_note!(user, vault, "A.md")
    assert :ok = perform_job(ReconcileEmbeddings, %{})
    assert_enqueued(worker: RebuildStaleNote, queue: :rebuild, args: %{"note_id" => note.id})
  end

  test "Voyage is asked with the maintenance purpose", %{user: user, vault: vault} do
    embedder_reporting(10)
    assert :ok = rebuild(stale_note!(user, vault, "A.md"))
    assert_received {:voyage, opts}
    assert opts[:purpose] == :maintenance
  end

  test "the bucket snoozes the 2nd job of a 150k-token minute", %{user: user, vault: vault} do
    first = stale_note!(user, vault, "A.md")
    second = stale_note!(user, vault, "B.md")
    embedder_reporting(150_000)

    assert :ok = rebuild(first)
    assert {:snooze, 30} = rebuild(second)

    assert Repo.with_tenant!(user.id, fn -> Repo.get!(Note, second.id) end).chunker_version ==
             elem(@pins, 0)
  end

  describe "optimizer gate" do
    for {name, info, queued} <- [
          {"a queued-points backlog", @green, 50_001},
          {"an update queue over 100", put_in(@green, ["update_queue", "length"], 101), 0},
          {"a yellow collection", %{@green | "status" => "yellow"}, 0},
          {"an optimizer error", %{@green | "optimizer_status" => %{"error" => "x"}}, 0}
        ] do
      test "#{name} snoozes before Voyage", %{user: user, vault: vault, health: health} do
        Agent.update(health, fn _ -> {unquote(Macro.escape(info)), unquote(queued)} end)
        expect(Engram.MockEmbedder, :embed_texts, 0, fn _, _ -> flunk("Voyage called") end)

        assert {:snooze, 30} = rebuild(stale_note!(user, vault, "A.md"))
      end
    end

    test "at the limits it runs", %{user: user, vault: vault, health: health} do
      Agent.update(health, fn _ -> {put_in(@green, ["update_queue", "length"], 100), 50_000} end)
      embedder_reporting(10)

      assert :ok = rebuild(stale_note!(user, vault, "A.md"))
    end

    test "the limit on queued points is configurable", %{user: user, vault: vault, health: h} do
      ServiceConfig.put_override(:rebuild_max_queued_points, 10)
      Agent.update(h, fn _ -> {@green, 11} end)

      assert {:snooze, 30} = rebuild(stale_note!(user, vault, "A.md"))
    end

    test "with the switch off nothing is gated", %{user: user, vault: vault, health: health} do
      ServiceConfig.put_override(:index_rebuild, "off")
      Agent.update(health, fn _ -> {%{@green | "status" => "red"}, 1_000_000} end)
      EngramWeb.RateLimiter.hit("voyage_maintenance_tpm", 60_000, 150_000, :voyage_embed, 200_000)

      # Off, a note behind the build but not the pins is not rebuilt at all.
      assert :ok = rebuild(stale_note!(user, vault, "A.md"))
    end
  end

  describe "order" do
    defp active!(user, days_ago, notes) do
      at = DateTime.add(DateTime.utc_now(), -days_ago * 86_400, :second)

      Repo.insert_all(
        Engram.UsageMeters.Meter,
        [%{user_id: user.id, last_active_at: at, notes_count: notes, updated_at: at}]
      )

      user
    end

    # Within a class the smaller account goes first (notes_count, none = 0).
    test "paid, then active Free smallest first, then inactive Free, then whales" do
      paid = insert(:subscription, tier: "pro").user |> active!(90, 50_000)
      big_free = active!(insert(:user), 1, 900)
      small_free = active!(insert(:user), 2, 10)
      idle_free = active!(insert(:user), 400, 5)
      never_seen = insert(:user)
      whale = insert(:subscription, tier: "starter").user |> active!(0, 1)
      ServiceConfig.put_override(:rebuild_last_users, [whale.id])

      ids = Enum.map([whale, idle_free, big_free, never_seen, small_free, paid], & &1.id)

      assert Rebuild.rebuild_order(ids) == [
               {paid.id, 6},
               {small_free.id, 7},
               {big_free.id, 7},
               {never_seen.id, 8},
               {idle_free.id, 8},
               {whale.id, 9}
             ]
    end

    test "the reconcile sweep queues each user at its priority", %{user: free, vault: vault} do
      sub = insert(:subscription, tier: "pro")
      {:ok, paid} = Crypto.ensure_user_dek(sub.user)
      paid_note = stale_note!(paid, insert(:vault, user: paid), "P.md")
      free_note = stale_note!(free, vault, "F.md")
      ServiceConfig.put_override(:rebuild_last_users, [free.id])

      assert :ok = perform_job(ReconcileEmbeddings, %{})

      assert_enqueued(worker: RebuildStaleNote, priority: 6, args: %{"note_id" => paid_note.id})
      assert_enqueued(worker: RebuildStaleNote, priority: 9, args: %{"note_id" => free_note.id})
    end
  end

  # H6: a maintenance embed that may have been billed is never re-sent. The
  # real client against a Voyage that answers 503 (which `:index` retries 3
  # times): exactly one HTTP call, and the job fails for Oban to retry later.
  test "H6 a maintenance Voyage failure makes 1 HTTP call", %{user: user, vault: vault} do
    voyage = Bypass.open()
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Bypass.stub(voyage, "POST", "/v1/embeddings", fn conn ->
      Agent.update(calls, &(&1 + 1))
      Plug.Conn.send_resp(conn, 503, ~s({"detail":"unavailable"}))
    end)

    previous = Application.get_env(:engram, :embedder)
    Application.put_env(:engram, :embedder, Engram.Embedders.Voyage)
    on_exit(fn -> Application.put_env(:engram, :embedder, previous) end)
    ServiceConfig.put_override(:voyage_url, "http://localhost:#{voyage.port}")
    ServiceConfig.put_override(:voyage_api_key, "test-key")

    assert {:error, _} = rebuild(stale_note!(user, vault, "A.md"))
    assert Agent.get(calls, & &1) == 1
  end
end
