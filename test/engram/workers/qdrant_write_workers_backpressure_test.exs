defmodule Engram.Workers.QdrantWriteWorkersBackpressureTest do
  # Every worker that writes to Qdrant snoozes on a strict-mode refusal
  # (`{:error, :qdrant_backpressure}`) instead of burning an Oban attempt.
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query, only: [from: 2]
  import Mox

  alias Engram.Crypto
  alias Engram.Indexing
  alias Engram.Notes
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.ServiceConfig
  alias Engram.Workers.{DeleteNoteIndex, RefreshKeywordVectors, RepathNoteIndex}

  setup :set_mox_global
  setup :verify_on_exit!

  @disk_refusal ~S|{"status":{"error":"Bad request: Disk usage is at 87% of total capacity, exceeding the configured limit of 85%. Help: Reduce disk usage (e.g. delete points or drop collections) or raise `max_disk_usage_percent` in strict mode."},"time":0.0001}|

  # Qdrant 1.19 node-wide quota refusal (lib/shard/src/quota/check.rs).
  @quota_refusal ~S|{"status":{"error":"Disk usage is at 95% of total capacity, exceeding the configured limit of 90%. Help: Reduce disk usage (e.g. delete points or drop collections), or raise `max_disk_usage_percent` in the global quota config."},"time":0.0001}|

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    {:ok, refuse} = Agent.start_link(fn -> %{} end)

    # Every route answers OK unless the test asked for it to be refused.
    Bypass.stub(bypass, :any, :any, fn conn ->
      key = {conn.method, conn.request_path}
      refused = Agent.get(refuse, & &1)

      {status, body} =
        cond do
          refused[key] == 507 ->
            {507, @quota_refusal}

          Map.has_key?(refused, key) ->
            {400, @disk_refusal}

          String.ends_with?(conn.request_path, "/points/count") ->
            {200, ~s({"result":{"count":2}})}

          true ->
            {200, ~s({"result":true,"status":"ok"})}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, body)
    end)

    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)

    {:ok, note} =
      Notes.upsert_note(
        user,
        vault,
        %{
          "path" => "plan.md",
          "content" => "# Plan\n\nRunning.\n\n## Notes\n\nDaily.",
          "mtime" => 1.0
        },
        actor: "api"
      )

    {:ok, note} = Crypto.maybe_decrypt_note_fields(note, user)

    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    {:ok, _} = Indexing.index_note(note, vault, user)

    refuse_route = fn method, path -> Agent.update(refuse, &Map.put(&1, {method, path}, 400)) end
    quota_refuse = fn method, path -> Agent.update(refuse, &Map.put(&1, {method, path}, 507)) end
    ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :qdrant, :backpressure]])
    %{note: note, user: user, refuse: refuse_route, quota_refuse: quota_refuse, ref: ref}
  end

  defp assert_backpressure_snooze(result, ref) do
    assert {:snooze, seconds} = result
    assert seconds in 30..90
    assert_received {[:engram, :qdrant, :backpressure], ^ref, %{count: 1}, %{reason: :refused}}
  end

  test "RefreshKeywordVectors snoozes when update_vectors is refused", ctx do
    ctx.refuse.("PUT", "/collections/engram_notes/points/vectors")

    perform_job(RefreshKeywordVectors, %{note_id: ctx.note.id, user_id: ctx.user.id})
    |> assert_backpressure_snooze(ctx.ref)
  end

  test "a Qdrant 1.19 quota refusal (HTTP 507) snoozes the same way", ctx do
    ctx.quota_refuse.("PUT", "/collections/engram_notes/points/vectors")

    perform_job(RefreshKeywordVectors, %{note_id: ctx.note.id, user_id: ctx.user.id})
    |> assert_backpressure_snooze(ctx.ref)
  end

  test "RepathNoteIndex snoozes when the payload PATCH is refused", ctx do
    ctx.refuse.("POST", "/collections/engram_notes/points/payload")

    perform_job(RepathNoteIndex, %{note_id: ctx.note.id, old_path_hmac: Base.encode64(<<7>>)})
    |> assert_backpressure_snooze(ctx.ref)
  end

  test "DeleteNoteIndex snoozes if a delete is ever refused", ctx do
    ctx.refuse.("POST", "/collections/engram_notes/points/delete")
    # Deleted, so the worker's resurrection check lets the delete run.
    Repo.update_all(
      from(n in Note, where: n.id == ^ctx.note.id),
      [set: [deleted_at: DateTime.utc_now()]],
      skip_tenant_check: true
    )

    perform_job(DeleteNoteIndex, %{
      note_id: ctx.note.id,
      user_id: ctx.user.id,
      vault_id: ctx.note.vault_id,
      path_hmac: Base.encode64(ctx.note.path_hmac)
    })
    |> assert_backpressure_snooze(ctx.ref)
  end
end
