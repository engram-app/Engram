defmodule Engram.Workers.ReconcileNotePayloadsTest do
  @moduledoc """
  Self-heal for users a DEK rotation already hit: their rows were rekeyed but
  every point kept the old filter HMACs. The reconcile reads the points,
  rewrites only the drifted ones with `set_payload` (no upsert, no embed) and
  stamps every checked note so the migration converges.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query, only: [from: 2]
  import Mox

  alias Engram.Crypto
  alias Engram.DataMigrations.NotePayloadStamps
  alias Engram.Indexing
  alias Engram.Notes
  alias Engram.Notes.{Chunk, Note}
  alias Engram.Workers.ReconcileNotePayloads

  setup :verify_on_exit!

  setup do
    {:ok, store} = Agent.start_link(fn -> %{points: %{}, upserts: 0, set_payloads: []} end)
    bypass = Bypass.open()
    Engram.ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    Bypass.stub(bypass, :any, :any, &fake_qdrant(&1, store))

    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    {:ok, user} = Engram.Fixtures.user_with_dek_fixture(dek_version: 1)
    vault = Engram.Fixtures.insert_vault!(user, "HealVault")

    [stale, healthy] =
      for path <- ["Ops/Stale.md", "Ops/Healthy.md"] do
        {:ok, note} =
          Notes.upsert_note(
            user,
            vault,
            %{
              "path" => path,
              "content" => "---\ntype: Playbook\ntags: [ops]\n---\n# T\n\nBody.\n"
            },
            actor: "api"
          )

        {:ok, plain} = Crypto.maybe_decrypt_note_fields(note, user)
        assert {:ok, _} = Indexing.index_note(plain, vault)
        note
      end

    # Written before `payload_hash` existed.
    {2, _} =
      Repo.update_all(from(n in Note, where: n.user_id == ^user.id), [set: [payload_hash: nil]],
        skip_tenant_check: true
      )

    # What a pre-fix rotation left behind: the point still on the old key.
    for id <- point_ids(stale) do
      Agent.update(store, fn s ->
        put_in(
          s.points[id],
          Map.merge(s.points[id], %{"type_hmac" => "b2xk", "tags_hmac" => ["b2xk"]})
        )
      end)
    end

    Agent.update(store, &%{&1 | upserts: 0})
    %{user: user, stale: stale, healthy: healthy, store: store}
  end

  test "rewrites only the drifted points, without re-embedding, and converges", ctx do
    expect(Engram.MockEmbedder, :embed_texts, 0, fn _ -> flunk("embed during reconcile") end)

    assert {:more, users: 1} = NotePayloadStamps.run_pass()
    assert :ok = perform_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id})

    raw = reload(ctx.stale)
    want = Indexing.expected_note_payload(raw) |> Jason.encode!() |> Jason.decode!()

    for id <- point_ids(ctx.stale) do
      point = Agent.get(ctx.store, &Map.fetch!(&1.points, id))
      assert point["type_hmac"] == want["type_hmac"]
      assert point["tags_hmac"] == want["tags_hmac"]
    end

    # One set_payload, for the drifted note only; the healthy one is just stamped.
    assert [ids] = Agent.get(ctx.store, & &1.set_payloads)
    assert Enum.sort(ids) == Enum.sort(point_ids(ctx.stale))
    assert Agent.get(ctx.store, & &1.upserts) == 0

    assert reload(ctx.stale).payload_hash
    assert reload(ctx.healthy).payload_hash
    assert NotePayloadStamps.run_pass() == :done
  end

  test "snoozes while the user's DEK rotation holds the lock", ctx do
    {1, _} =
      Repo.update_all(
        from(u in Engram.Accounts.User, where: u.id == ^ctx.user.id),
        [set: [dek_rotation_locked_at: DateTime.utc_now()]],
        skip_tenant_check: true
      )

    assert {:snooze, 60} = perform_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id})
    assert Agent.get(ctx.store, & &1.set_payloads) == []
  end

  test "a user with nothing unstamped is done", ctx do
    assert :ok = perform_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id})
    Agent.update(ctx.store, &%{&1 | set_payloads: []})

    assert :ok = perform_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id})
    assert Agent.get(ctx.store, & &1.set_payloads) == []
    assert NotePayloadStamps.run_pass() == :done
  end

  defp reload(note),
    do: Repo.one!(from(n in Note, where: n.id == ^note.id), skip_tenant_check: true)

  defp point_ids(note) do
    Repo.all(from(c in Chunk, where: c.note_id == ^note.id, select: c.qdrant_point_id),
      skip_tenant_check: true
    )
  end

  defp fake_qdrant(conn, store) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)
    body = if body == "", do: %{}, else: Jason.decode!(body)

    result =
      case {conn.method, conn.request_path} do
        {"PUT", "/collections/engram_notes/points"} ->
          Agent.update(store, fn s ->
            points = Map.new(body["points"], &{&1["id"], &1["payload"]})
            %{s | points: Map.merge(s.points, points), upserts: s.upserts + 1}
          end)

          %{"status" => "completed"}

        {"POST", "/collections/engram_notes/points/payload"} ->
          Agent.update(store, fn s ->
            points =
              Enum.reduce(body["points"], s.points, fn id, acc ->
                Map.update(acc, id, body["payload"], &Map.merge(&1, body["payload"]))
              end)

            %{s | points: points, set_payloads: [body["points"] | s.set_payloads]}
          end)

          %{"status" => "completed"}

        {"POST", "/collections/engram_notes/points/scroll"} ->
          ids =
            for %{"has_id" => ids} <- get_in(body, ["filter", "must"]) || [], id <- ids, do: id

          points = Agent.get(store, & &1.points)

          %{
            "points" =>
              for(
                id <- ids,
                Map.has_key?(points, id),
                do: %{"id" => id, "payload" => Map.take(points[id], body["with_payload"])}
              ),
            "next_page_offset" => nil
          }

        _other ->
          true
      end

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"result" => result, "status" => "ok"}))
  end
end
