defmodule Engram.RebuildLedgerWiringTest do
  @moduledoc """
  The v5 rebuild ledger on the real worker path (`RebuildStaleNote`, which
  runs `EmbedNote`'s version-rebuild route): a halt stops queued rebuilds
  before Voyage, the ledger is debited what Voyage reported, and a note
  that drifts past its estimate is parked.

  async: false: global Mox mode and the reconcile/Oban state.
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
  alias Engram.Workers.{EmbedNote, RebuildStaleNote}

  setup :set_mox_global
  setup :verify_on_exit!

  # Build at chunker 3 / keyword 2, pins at 2 / 1: a note stamped 2 is the
  # pass's to rebuild only while the switch is `on`.
  @pins {Markdown.chunker_version() - 1, KeywordIndex.version() - 1}

  setup do
    Engram.Cache.clear_local(:rebuild)
    Repo.query!("DELETE FROM rebuild_ledger")
    ServiceConfig.put_override(:rebuild_pinned_versions, @pins)
    ServiceConfig.put_override(:write_v5_layout, true)
    ServiceConfig.put_override(:index_rebuild, "on")

    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

    # A green, caught-up collection for `Rebuild.gate/0`; every write succeeds,
    # and every point read back holds a dense vector (the v5 rebuild copies
    # it, Task 16.3).
    col = "/collections/#{Engram.Vector.Qdrant.collection_name()}"
    green = ~s({"result": {"status": "green", "optimizer_status": "ok"}, "status": "ok"})
    idle = ~s({"result": {"summary": {"queued_points": 0}, "running": []}, "status": "ok"})
    points = col <> "/points"

    Bypass.stub(bypass, :any, :any, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      body =
        case {conn.method, conn.request_path} do
          {"GET", ^col} -> green
          {"GET", path} when path == col <> "/optimizations" -> idle
          {"POST", ^points} -> read_back(raw)
          _ -> ~s({"result": true, "status": "ok"})
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end)

    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)

    # Content current and dense, never chunked: the rebuild embeds it all.
    {:ok, note} =
      Notes.upsert_note(
        user,
        vault,
        %{"path" => "A.md", "content" => "# Alpha\n\nalpha words here", "mtime" => 1.0},
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

    %{user: user, vault: vault, note: note}
  end

  # A Voyage stand-in that reports `tokens` the way the real client does. A
  # RebuildStaleNote pass calls it with `purpose: :maintenance`.
  defp embedder_reporting(tokens) do
    stub(Engram.MockEmbedder, :embed_texts, fn texts, _opts ->
      :telemetry.execute(
        [:engram, :voyage, :embed, :tokens],
        %{total_tokens: tokens},
        %{purpose: :index}
      )

      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)
  end

  defp rebuild(note),
    do: perform_job(RebuildStaleNote, %{"note_id" => note.id, "user_id" => note.user_id})

  defp reload(note), do: Repo.with_tenant!(note.user_id, fn -> Repo.get!(Note, note.id) end)

  test "the ledger is debited exactly what Voyage reported", %{note: note} do
    Rebuild.set_budget(10_000)
    embedder_reporting(123)

    assert :ok = rebuild(note)
    assert Rebuild.ledger().spent_tokens == 123
  end

  test "a job queued before a halt makes 0 Voyage calls", %{note: note} do
    Rebuild.set_budget(1)
    assert Rebuild.debit(2) == :halt
    expect(Engram.MockEmbedder, :embed_texts, 0, fn _, _ -> flunk("Voyage called after halt") end)

    assert :ok = rebuild(note)
    assert Rebuild.ledger().spent_tokens == 2
    # Not rebuilt: still behind the build, waiting for `on`.
    assert reload(note).chunker_version == elem(@pins, 0)
  end

  test "a debit past the budget halts, so the next queued job makes 0 calls", ctx do
    %{note: note, user: user, vault: vault} = ctx
    Rebuild.set_budget(100)
    embedder_reporting(500)
    assert :ok = rebuild(note)
    assert Rebuild.mode() == :off

    {:ok, other} =
      Notes.upsert_note(
        user,
        vault,
        %{"path" => "B.md", "content" => "# Beta\n\nbeta words", "mtime" => 1.0},
        actor: "api"
      )

    Repo.with_tenant!(user.id, fn ->
      Repo.update_all(from(n in Note, where: n.id == ^other.id),
        set: [
          embed_hash: other.content_hash,
          dense_indexed_hash: other.content_hash,
          chunker_version: elem(@pins, 0)
        ]
      )
    end)

    expect(Engram.MockEmbedder, :embed_texts, 0, fn _, _ -> flunk("Voyage called after halt") end)
    assert :ok = rebuild(other)
  end

  test "a note that drifts past 1.5x its estimate and 50k tokens is parked", ctx do
    %{note: note, user: user, vault: vault} = ctx
    Rebuild.set_budget(1_000_000)

    :ok =
      Rebuild.put_manifest(user.id, [
        %{
          note_id: note.id,
          vault_id: vault.id,
          est_tokens: 10,
          new_points: 1,
          reused_points: 0,
          mean_pooled_points: 0,
          dl_sum: 3,
          dl_count: 1
        }
      ])

    ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :rebuild, :drift_parked]])
    embedder_reporting(60_000)

    assert :ok = rebuild(note)
    assert_received {[:engram, :rebuild, :drift_parked], ^ref, %{tokens: 60_000}, _}
    assert reload(note).embed_retry_after == EmbedNote.parked_until_edited()
  end

  # Oban kills a job past its timeout (and a node can die mid-pass): an
  # `after` never runs then, so tokens Voyage already reported must be on
  # the ledger the moment they are reported.
  test "a rebuild killed mid-pass still debits what Voyage already reported", %{note: note} do
    Rebuild.set_budget(10_000)
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())

        Rebuild.spend(note, fn ->
          :telemetry.execute([:engram, :voyage, :embed, :tokens], %{total_tokens: 77}, %{})
          Process.exit(self(), :kill)
        end)
      end)

    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
    assert Rebuild.ledger().spent_tokens == 77
  end

  @handler "engram-rebuild-token-meter"

  defp meter_attached?,
    do:
      Enum.any?(
        :telemetry.list_handlers([:engram, :voyage, :embed, :tokens]),
        &(&1.id == @handler)
      )

  defp tokens(n),
    do: :telemetry.execute([:engram, :voyage, :embed, :tokens], %{total_tokens: n}, %{})

  # `:telemetry` detaches a handler that raises, for good: every later
  # rebuild on the node would then go unmetered. A malformed count makes
  # `debit/1` raise a FunctionClauseError, which is not a DB error.
  test "a debit that raises keeps the meter attached; the next response is debited live",
       %{note: note} do
    Rebuild.set_budget(10_000)
    me = self()

    :ok =
      :telemetry.attach(
        "meter-failed-probe",
        [:engram, :rebuild, :meter_failed],
        fn _event, m, _meta, _ -> send(me, {:meter_failed, m.tokens}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach("meter-failed-probe") end)

    assert :done =
             Rebuild.spend(note, fn ->
               tokens(-1)
               tokens(10)
               send(me, {:mid, Rebuild.ledger().spent_tokens, meter_attached?()})
               :done
             end)

    assert_received {:meter_failed, -1}
    assert_received {:mid, 10, true}
    assert meter_attached?()
    assert Rebuild.ledger().spent_tokens == 10
  end

  # A debit that fails for a while (the ledger is unreachable for the first
  # response) is charged when the rebuild ends.
  test "a failed live debit is charged when the rebuild ends", %{note: note} do
    Rebuild.set_budget(10_000)
    me = self()

    assert :done =
             Rebuild.spend(note, fn ->
               Repo.query!("ALTER TABLE rebuild_ledger RENAME TO rebuild_ledger_away")
               tokens(5)
               Repo.query!("ALTER TABLE rebuild_ledger_away RENAME TO rebuild_ledger")
               tokens(10)
               send(me, {:mid, Rebuild.ledger().spent_tokens})
               :done
             end)

    assert_received {:mid, 10}
    assert Rebuild.ledger().spent_tokens == 15
    assert meter_attached?()
  end

  test "spend re-attaches a meter that went missing before calling Voyage", %{note: note} do
    Rebuild.set_budget(10_000)
    :ok = :telemetry.detach(@handler)
    refute meter_attached?()

    assert :ok = Rebuild.spend(note, fn -> tokens(7) end)
    assert meter_attached?()
    assert Rebuild.ledger().spent_tokens == 7
  end

  test "an indexed note whose content did not change rebuilds with 0 Voyage calls", ctx do
    %{note: note, user: user} = ctx
    Rebuild.set_budget(10_000)
    me = self()

    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      send(me, :voyage_call)
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    # A first, real index through the worker (content changed): dense.
    stamp = fn set ->
      Repo.with_tenant!(user.id, fn ->
        Repo.update_all(from(n in Note, where: n.id == ^note.id), set: set)
      end)
    end

    stamp.(embed_hash: nil, dense_indexed_hash: nil)
    assert :ok = perform_job(EmbedNote, %{"note_id" => note.id, "user_id" => user.id})
    assert_received :voyage_call
    assert reload(note).dense_indexed_hash == note.content_hash

    # Then only the index version moves: the rebuild reuses every vector.
    stamp.(chunker_version: elem(@pins, 0), keyword_version: elem(@pins, 1))
    flush_voyage_calls()

    assert :ok = rebuild(note)
    refute_received :voyage_call
    assert Rebuild.ledger().spent_tokens == 0
    assert reload(note).chunker_version == Markdown.chunker_version()
  end

  defp read_back(raw) do
    ids = Jason.decode!(raw)["ids"]
    result = for id <- ids, do: %{id: id, vector: %{dense: [0.1, 0.2, 0.3]}}
    Jason.encode!(%{result: result, status: "ok"})
  end

  defp flush_voyage_calls do
    receive do
      :voyage_call -> flush_voyage_calls()
    after
      0 -> :ok
    end
  end

  test "with the switch off the job rebuilds nothing and spends nothing", %{note: note} do
    ServiceConfig.put_override(:index_rebuild, "off")
    expect(Engram.MockEmbedder, :embed_texts, 0, fn _, _ -> flunk("Voyage called while off") end)

    assert :ok = rebuild(note)
    assert Rebuild.ledger() == nil
  end
end
