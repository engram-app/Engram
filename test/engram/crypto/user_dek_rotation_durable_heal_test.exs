defmodule Engram.Crypto.UserDekRotationDurableHealTest do
  @moduledoc """
  What a DEK rotation leaves for after its flip is owned by jobs that commit
  WITH the flip, so a node that dies right after it loses nothing:

    * the filter keys on every point, v3 and v5 (`ReconcileNotePayloads`),
      built from the note rows as they are when the job runs, so an edit
      that lands after the flip is never reverted;
    * the point text, which only the rotating process can rewrap (it alone
      holds the retired DEK): `RotationTextGuard` runs later unless that
      process finished, and rebuilds only the notes whose text is unreadable.

  A Qdrant failure in either is an Oban retry, never a re-embed.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query, only: [from: 2]

  alias Engram.Crypto
  alias Engram.Crypto.{Envelope, UserDekRotation}
  alias Engram.Vector.FilterId
  alias Engram.Workers.{EmbedNote, ReconcileNotePayloads, RotationTextGuard}

  @content "---\ntype: Playbook\ntags: [ops]\nstatus: draft\n---\nbody\n"

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture(dek_version: 1)
    vault = Engram.Fixtures.insert_vault!(user, "HealVault")

    {:ok, note} =
      Engram.Notes.upsert_note(user, vault, %{"path" => "heal/keys.md", "content" => @content},
        actor: "api"
      )

    {1, _} =
      Repo.update_all(
        from(n in Engram.Notes.Note,
          where: n.id == ^note.id,
          update: [set: [embed_hash: n.content_hash, chunker_version: 1]]
        ),
        [],
        skip_tenant_check: true
      )

    # The upsert's own debounced embed: these tests assert nothing new is queued.
    Repo.delete_all(Oban.Job)

    point = Ecto.UUID.generate()

    Repo.insert!(
      %Engram.Notes.Chunk{
        note_id: note.id,
        user_id: user.id,
        vault_id: vault.id,
        position: 0,
        char_start: 0,
        char_end: 4,
        qdrant_point_id: point
      },
      skip_tenant_check: true
    )

    Engram.ServiceConfig.put_override(:v5_payload_format, true)

    # A rotation and its heals never reach the embedder.
    Mox.stub(Engram.MockEmbedder, :embed_texts, fn _ -> flunk("embed during a rotation heal") end)

    {:ok, user: user, note: note, point: point}
  end

  # `sweep`: the points the text sweep scrolls (filter on `user_id`).
  # `heal`: what the payload heal reads back for its `has_id` page.
  # `overwrite_status`: the PUT /points/payload answer.
  defp stub_qdrant(opts) do
    bypass = Bypass.open()
    Engram.ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    test = self()
    sweep = Keyword.get(opts, :sweep, [])
    heal = Keyword.get(opts, :heal, [])
    status = Keyword.get(opts, :overwrite_status, 200)

    Bypass.stub(bypass, "POST", "/collections/engram_notes/points/scroll", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"filter" => filter} = Jason.decode!(body)

      points =
        if Enum.any?(filter["must"] || [], &Map.has_key?(&1, "has_id")), do: heal, else: sweep

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"result" => %{"points" => points, "next_page_offset" => nil}})
      )
    end)

    for method <- ["POST", "PUT"] do
      Bypass.stub(bypass, method, "/collections/engram_notes/points/payload", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:payload_write, method, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, ~s({"result": {"status": "completed"}, "status": "ok"}))
      end)
    end

    for path <- ["/points/batch", "/points/payload/delete", "/points/delete"] do
      Bypass.stub(bypass, "POST", "/collections/engram_notes#{path}", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        resp =
          case Jason.decode!(body) do
            %{"operations" => ops} ->
              Jason.encode!(%{result: Enum.map(ops, fn _ -> %{status: "acknowledged"} end)})

            _ ->
              ~s({"result":{"status":"completed"},"status":"ok"})
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, resp)
      end)
    end

    bypass
  end

  # A v5 point still on the retired key: its type id is not the new one.
  defp stale_v5(point, user),
    do: [%{"id" => point, "payload" => %{"u" => FilterId.uuid(user.id), "y" => "stale"}}]

  defp new_filter_key(user),
    do: Crypto.dek_filter_key(Repo.get!(Engram.Accounts.User, user.id))

  defp heal!(user), do: perform_job(ReconcileNotePayloads, %{"user_id" => user.id})

  test "the rotation leaves the v5 filter keys to the job the flip commits", ctx do
    stub_qdrant(heal: stale_v5(ctx.point, ctx.user))

    assert :ok = UserDekRotation.rotate_user(ctx.user.id)

    # Nothing in-process: a node dying here loses no Qdrant write.
    refute_received {:payload_write, _, _}
    assert_enqueued(worker: ReconcileNotePayloads, args: %{"user_id" => ctx.user.id})

    assert :ok = heal!(ctx.user)
    {:ok, new_fk} = new_filter_key(ctx.user)

    assert_received {:payload_write, "PUT",
                     %{"filter" => %{"should" => [%{"has_id" => [point]}]}, "payload" => p}}

    assert point == ctx.point
    assert p["y"] == FilterId.from_hmac(Crypto.hmac_field(new_fk, "playbook"))
  end

  test "an edit after the flip is healed from the row as it is now", ctx do
    stub_qdrant(heal: stale_v5(ctx.point, ctx.user))
    assert :ok = UserDekRotation.rotate_user(ctx.user.id)
    {:ok, new_fk} = new_filter_key(ctx.user)

    # Committed after the flip, its own index not run yet (no payload stamp).
    edited = Crypto.hmac_field(new_fk, "runbook")

    {1, _} =
      Repo.update_all(
        from(n in Engram.Notes.Note, where: n.id == ^ctx.note.id),
        [set: [type_hmac: edited]],
        skip_tenant_check: true
      )

    assert :ok = heal!(ctx.user)
    assert_received {:payload_write, "PUT", %{"payload" => p}}
    assert p["y"] == FilterId.from_hmac(edited)
  end

  test "a note an index already re-stamped since the flip is left alone", ctx do
    stub_qdrant(heal: stale_v5(ctx.point, ctx.user))
    assert :ok = UserDekRotation.rotate_user(ctx.user.id)

    {1, _} =
      Repo.update_all(
        from(n in Engram.Notes.Note, where: n.id == ^ctx.note.id),
        [set: [payload_hash: "written-by-a-later-index"]],
        skip_tenant_check: true
      )

    assert :ok = heal!(ctx.user)
    refute_received {:payload_write, _, _}
  end

  test "a Qdrant failure is retried by the heal and costs no re-embed", ctx do
    stub_qdrant(heal: stale_v5(ctx.point, ctx.user), overwrite_status: 500)

    assert :ok = UserDekRotation.rotate_user(ctx.user.id)
    assert {:error, _} = heal!(ctx.user)

    refute_enqueued(worker: EmbedNote)

    raw =
      Repo.one!(from(n in Engram.Notes.Note, where: n.id == ^ctx.note.id),
        skip_tenant_check: true
      )

    assert raw.chunker_version == 1
    assert raw.payload_hash == nil, "left for the retry"
  end

  describe "the point-text guard" do
    test "is committed by the flip and cancelled once the rotation finishes", ctx do
      stub_qdrant([])
      assert :ok = UserDekRotation.rotate_user(ctx.user.id)

      [job] =
        Repo.all(from(j in Oban.Job, where: j.worker == ^inspect(RotationTextGuard)),
          skip_tenant_check: true
        )

      assert job.args == %{"user_id" => ctx.user.id, "dek_version" => 2}
      assert DateTime.diff(job.scheduled_at, job.inserted_at) >= RotationTextGuard.delay_seconds()
      assert job.state == "cancelled"
    end

    test "after a crash: rebuilds only the notes whose text is unreadable", ctx do
      {ct, nonce} = Envelope.encrypt("text", :crypto.strong_rand_bytes(32), <<>>)

      unreadable = %{
        "id" => ctx.point,
        "payload" => %{
          "user_id" => ctx.user.id,
          "text" => Base.encode64(ct),
          "text_nonce" => Base.encode64(nonce)
        }
      }

      stub_qdrant(sweep: [unreadable])

      assert :ok =
               perform_job(RotationTextGuard, %{
                 "user_id" => ctx.user.id,
                 "dek_version" => ctx.user.dek_version || 1
               })

      raw =
        Repo.one!(from(n in Engram.Notes.Note, where: n.id == ^ctx.note.id),
          skip_tenant_check: true
        )

      assert raw.chunker_version == nil
      assert_enqueued(worker: EmbedNote, args: %{note_id: ctx.note.id})
    end

    test "a later rotation owns its own guard", ctx do
      stub_qdrant([])

      assert :ok =
               perform_job(RotationTextGuard, %{"user_id" => ctx.user.id, "dek_version" => 99})

      refute_enqueued(worker: EmbedNote)
    end

    test "a Qdrant failure is a retry, not a re-embed", ctx do
      bypass = Bypass.open()
      Engram.ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

      Bypass.stub(bypass, "POST", "/collections/engram_notes/points/scroll", fn conn ->
        Plug.Conn.send_resp(conn, 503, "{}")
      end)

      assert {:error, _} =
               perform_job(RotationTextGuard, %{
                 "user_id" => ctx.user.id,
                 "dek_version" => ctx.user.dek_version || 1
               })

      refute_enqueued(worker: EmbedNote)
    end
  end
end
