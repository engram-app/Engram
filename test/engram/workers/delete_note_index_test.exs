defmodule Engram.Workers.DeleteNoteIndexTest do
  @moduledoc """
  #1608: a failed Qdrant delete used to be discarded and the job returned
  `:ok`, so the rows and points both survived and the deleted note stayed
  searchable with nothing left to retry it.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query

  alias Engram.Notes.Chunk
  alias Engram.Repo
  alias Engram.Workers.DeleteNoteIndex

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user)
    note = insert(:note, user: user, vault: vault)

    Repo.insert!(
      %Chunk{
        note_id: note.id,
        user_id: user.id,
        vault_id: vault.id,
        position: 0,
        char_start: 0,
        char_end: 1,
        qdrant_point_id: Ecto.UUID.generate()
      },
      skip_tenant_check: true
    )

    %{bypass: bypass, user: user, vault: vault, note: note}
  end

  defp args(note) do
    %{
      "note_id" => note.id,
      "user_id" => note.user_id,
      "vault_id" => note.vault_id,
      "path_hmac" => Base.encode64(note.path_hmac)
    }
  end

  defp chunk_count(note) do
    Repo.aggregate(from(c in Chunk, where: c.note_id == ^note.id), :count,
      skip_tenant_check: true
    )
  end

  test "returns the Qdrant error so Oban retries, keeping the rows", %{
    bypass: bypass,
    note: note
  } do
    Bypass.expect(bypass, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(500, ~s({"status":{"error":"boom"}}))
    end)

    assert {:error, _} = perform_job(DeleteNoteIndex, args(note))
    assert chunk_count(note) == 1
  end

  # The edge flip used to run unconditionally. Putting it behind the retryable
  # Qdrant delete means a brief 5xx burns all three attempts and the deleted
  # note keeps its outgoing edges forever, since nothing re-enqueues this job.
  test "drops the note's link edges even when the Qdrant delete fails", %{
    bypass: bypass,
    user: user,
    vault: vault,
    note: note
  } do
    :ok =
      Engram.Links.replace_links(user, vault, note.id, Engram.Links.Parser.extract("[[Other]]"))

    assert Repo.aggregate(
             from(l in Engram.Links.NoteLink, where: l.source_note_id == ^note.id),
             :count,
             skip_tenant_check: true
           ) == 1

    Bypass.expect(bypass, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(500, ~s({"status":{"error":"boom"}}))
    end)

    assert {:error, _} = perform_job(DeleteNoteIndex, args(note))

    assert Repo.aggregate(
             from(l in Engram.Links.NoteLink, where: l.source_note_id == ^note.id),
             :count,
             skip_tenant_check: true
           ) == 0
  end

  test "deletes the rows once Qdrant accepts the delete", %{bypass: bypass, note: note} do
    Bypass.expect(bypass, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result":{"status":"completed"}}))
    end)

    assert :ok = perform_job(DeleteNoteIndex, args(note))
    assert chunk_count(note) == 0
  end
end
