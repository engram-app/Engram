defmodule Engram.Indexing.CommitIndexParamCapTest do
  @moduledoc """
  Regression for the 2026-10-19 prod crash: EmbedNote failed 5 times on a note
  with ~7,304 chunks with `postgresql protocol can not handle 73040 parameters,
  the maximum is 65535`. A chunk row binds 10 parameters, so ONE unbatched
  `insert_all` overflows the wire protocol past 6,553 rows.

  Drives `commit_index/2` directly with synthetic rows: chunking a real note
  that many times is slow, and the bug is purely in the row write.
  """

  use Engram.DataCase, async: false

  import Ecto.Query

  alias Engram.Indexing
  alias Engram.Notes
  alias Engram.Notes.Chunk
  alias Engram.Repo

  # One past the overflow point at 10 binds per row (65535 / 10 = 6553).
  @rows 7_000

  setup do
    bypass = Bypass.open()
    Engram.ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

    Bypass.stub(bypass, :any, :any, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true, "status": "ok"}))
    end)

    user = insert(:user)
    vault = insert(:vault, user: user)

    {:ok, note} =
      Notes.upsert_note(
        user,
        vault,
        %{"path" => "Big/Chunky.md", "content" => "# Big", "mtime" => 1_000.0},
        actor: "api"
      )

    {:ok, note: note}
  end

  test "writes more chunk rows than one statement's parameter cap allows", %{note: note} do
    now = DateTime.utc_now(:second)

    rows =
      for i <- 1..@rows do
        %{
          note_id: note.id,
          user_id: note.user_id,
          vault_id: note.vault_id,
          position: i,
          char_start: i,
          char_end: i + 1,
          token_count: 1,
          qdrant_point_id: Ecto.UUID.generate(),
          context_hmac: "h#{i}",
          created_at: now
        }
      end

    prepared = %{
      note: note,
      chunk_rows: rows,
      qdrant_points: [],
      reused_point_ids: [],
      stale_point_ids: [],
      note_payload: %{},
      payload_hash: :crypto.hash(:sha256, "fixture"),
      point_kinds: []
    }

    assert {:ok, @rows} = Indexing.commit_index(prepared)

    count =
      Repo.with_tenant(note.user_id, fn ->
        Repo.one(from(c in Chunk, where: c.note_id == ^note.id, select: count()),
          skip_tenant_check: true
        )
      end)

    assert count == {:ok, @rows}
  end
end
