defmodule Engram.Workers.RepathNoteIndexTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query, only: [from: 2]
  import Mox

  alias Engram.Crypto
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Workers.{EmbedNote, RepathNoteIndex}

  setup :verify_on_exit!

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user)

    note =
      Engram.Fixtures.insert_note!(user, vault, %{
        path: "New/Hello.md",
        content: "# Hello\n\nWorld."
      })

    # Simulate an already-embedded note: embed_hash == content_hash.
    from(n in Note, where: n.id == ^note.id)
    |> Repo.update_all([set: [embed_hash: note.content_hash]], skip_tenant_check: true)

    %{bypass: bypass, note: %{note | embed_hash: note.content_hash}}
  end

  defp stub_count(bypass, count) do
    Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/count", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": {"count": #{count}}}))
    end)
  end

  test "PATCHes payload, emits repath:ok telemetry, makes no embedder call", %{
    bypass: bypass,
    note: note
  } do
    stub_count(bypass, 2)

    Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/payload", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["payload"]["path_hmac"] == Base.encode64(note.path_hmac)
      Plug.Conn.send_resp(conn, 200, ~s({"result": true}))
    end)

    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      "repath-stop-#{inspect(ref)}",
      [:engram, :indexing, :repath, :stop],
      fn _event, measurements, meta, _ -> send(test_pid, {ref, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("repath-stop-#{inspect(ref)}") end)

    # No Mox expectation on Engram.MockEmbedder — if it embeds, the test fails.
    assert :ok =
             perform_job(RepathNoteIndex, %{note_id: note.id, old_path_hmac: Base.encode64(<<7>>)})

    # Single event tagged by outcome; measurement carries the patched point count.
    assert_received {^ref, %{count: 2}, %{outcome: :ok}}
  end

  test "enqueues EmbedNote when zero points and content not yet embedded", %{
    bypass: bypass,
    note: note
  } do
    # Make the note look unembedded: clear embed_hash.
    from(n in Note, where: n.id == ^note.id)
    |> Repo.update_all([set: [embed_hash: nil]], skip_tenant_check: true)

    stub_count(bypass, 0)

    assert :ok =
             perform_job(RepathNoteIndex, %{note_id: note.id, old_path_hmac: Base.encode64(<<7>>)})

    assert_enqueued(worker: EmbedNote, args: %{note_id: note.id})
  end

  test "warns (no enqueue) when zero points but note is marked embedded", %{
    bypass: bypass,
    note: note
  } do
    stub_count(bypass, 0)

    assert :ok =
             perform_job(RepathNoteIndex, %{note_id: note.id, old_path_hmac: Base.encode64(<<7>>)})

    refute_enqueued(worker: EmbedNote)
  end

  test "discards when note is missing" do
    assert {:discard, _} =
             perform_job(RepathNoteIndex, %{
               note_id: "00000000-0000-0000-0000-000000999999",
               old_path_hmac: Base.encode64(<<7>>)
             })
  end

  test "discards when note is soft-deleted", %{note: note} do
    from(n in Note, where: n.id == ^note.id)
    |> Repo.update_all([set: [deleted_at: DateTime.utc_now()]], skip_tenant_check: true)

    assert {:discard, _} =
             perform_job(RepathNoteIndex, %{
               note_id: note.id,
               old_path_hmac: Base.encode64(<<7>>)
             })
  end

  test "returns error so Oban retries when Qdrant count fails", %{bypass: bypass, note: note} do
    Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/count", fn conn ->
      Plug.Conn.send_resp(conn, 503, ~s({"status":"error"}))
    end)

    assert {:error, _} =
             perform_job(RepathNoteIndex, %{note_id: note.id, old_path_hmac: Base.encode64(<<7>>)})
  end

  test "non-final attempt with Qdrant 503 returns error (Oban retries, no EmbedNote)", %{
    bypass: bypass,
    note: note
  } do
    Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/count", fn conn ->
      Plug.Conn.send_resp(conn, 503, ~s({"status":"error"}))
    end)

    assert {:error, _} =
             perform_job(
               RepathNoteIndex,
               %{note_id: note.id, old_path_hmac: Base.encode64(<<7>>)},
               attempt: 1,
               max_attempts: 5
             )

    refute_enqueued(worker: EmbedNote)
  end

  test "final attempt with Qdrant 503 falls back to EmbedNote and returns :ok", %{
    bypass: bypass,
    note: note
  } do
    old_path_hmac = Base.encode64(<<7>>)

    Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/count", fn conn ->
      Plug.Conn.send_resp(conn, 503, ~s({"status":"error"}))
    end)

    assert :ok =
             perform_job(
               RepathNoteIndex,
               %{note_id: note.id, old_path_hmac: old_path_hmac},
               attempt: 5,
               max_attempts: 5
             )

    assert_enqueued(worker: EmbedNote, args: %{note_id: note.id, old_path_hmac: old_path_hmac})
  end

  test "final attempt with repath PATCH 503 falls back to EmbedNote and returns :ok", %{
    bypass: bypass,
    note: note
  } do
    old_path_hmac = Base.encode64(<<7>>)

    # Points exist (count > 0) but the payload PATCH itself keeps failing. The
    # other exhaustion test fails the COUNT call; this one exercises the
    # repath_points/2 error arm of maybe_fallback/4 (#755).
    stub_count(bypass, 2)

    Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/payload", fn conn ->
      Plug.Conn.send_resp(conn, 503, ~s({"status":"error"}))
    end)

    assert :ok =
             perform_job(
               RepathNoteIndex,
               %{note_id: note.id, old_path_hmac: old_path_hmac},
               attempt: 5,
               max_attempts: 5
             )

    assert_enqueued(worker: EmbedNote, args: %{note_id: note.id, old_path_hmac: old_path_hmac})
  end
end
