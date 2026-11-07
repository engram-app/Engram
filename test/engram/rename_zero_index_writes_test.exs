defmodule Engram.RenameZeroIndexWritesTest do
  @moduledoc """
  Hard invariant (R3a, Todd): renaming or moving a note or a folder makes
  ZERO Qdrant requests and ZERO Voyage calls, across the rename AND every
  job it enqueues (drained, with recursion).

  Counted at the shared clients, not at a telemetry event: every Qdrant
  HTTP request (any caller, any op) hits the Bypass at `:qdrant_url`, and
  every embed goes through the `Engram.Embedder` seam (`MockEmbedder`).
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Mox

  alias Engram.Notes

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    test = self()

    bypass = Bypass.open()
    Engram.ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

    Bypass.stub(bypass, :any, :any, fn conn ->
      send(test, {:qdrant, conn.method, conn.request_path})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": {}}))
    end)

    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      send(test, {:voyage, length(texts)})
      {:error, :counted}
    end)

    stub(Engram.MockEmbedder, :embed_texts, fn texts, _opts ->
      send(test, {:voyage, length(texts)})
      {:error, :counted}
    end)

    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Test", Ecto.UUID.generate())

    ids =
      Map.new(["A/One.md", "A/Two.md", "A/Sub/Three.md", "B/Keep.md"], fn path ->
        note = Engram.Fixtures.insert_note!(user, vault, %{path: path, content: "# x\n\n#{path}"})

        # Already embedded: nothing about it is stale.
        from(n in Engram.Notes.Note, where: n.id == ^note.id)
        |> Repo.update_all([set: [embed_hash: note.content_hash]], skip_tenant_check: true)

        {path, note.id}
      end)

    %{user: user, vault: vault, ids: ids}
  end

  # Runs every job the rename queued, and what those queue in turn, in a
  # bounded number of passes: a job that snoozes or retries (a paced worker
  # that cannot read Qdrant) is rescheduled each pass, so draining "until
  # empty" would never end.
  defp drain_all do
    for _pass <- 1..3, queue <- queues(), do: Oban.drain_queue(queue: queue, with_scheduled: true)
  end

  defp queues do
    Oban.Job
    |> Repo.all(skip_tenant_check: true)
    |> Enum.map(&String.to_existing_atom(&1.queue))
    |> Enum.uniq()
  end

  defp assert_zero_index_calls(rename) do
    assert {:ok, _} = rename.()
    drain_all()

    refute_received {:qdrant, _, _}
    refute_received {:voyage, _}
  end

  test "note rename (same folder)", %{user: u, vault: v} do
    assert_zero_index_calls(fn -> Notes.rename_note(u, v, "A/One.md", "A/Uno.md") end)
  end

  test "note move (another folder)", %{user: u, vault: v} do
    assert_zero_index_calls(fn -> Notes.rename_note(u, v, "A/One.md", "B/One.md") end)
  end

  test "folder rename (same parent)", %{user: u, vault: v} do
    assert_zero_index_calls(fn -> Notes.rename_folder(u, v, "A", "Z") end)
  end

  test "folder move (into another folder)", %{user: u, vault: v} do
    assert_zero_index_calls(fn -> Notes.rename_folder(u, v, "A/Sub", "B/Sub") end)
  end

  # A live note whose embed is not current (a poison cooldown, a budget
  # park, an edit still in its debounce) is moved as it is: the move must
  # not queue the embed its state is holding back.
  test "web-app move of a live note whose embed is stale (in cooldown)",
       %{user: u, vault: v, ids: ids} do
    id = ids["A/Two.md"]

    from(n in Engram.Notes.Note, where: n.id == ^id)
    |> Repo.update_all(
      [set: [embed_hash: "stale", embed_retry_after: DateTime.add(DateTime.utc_now(), 3600)]],
      skip_tenant_check: true
    )

    assert {:ok, _} = Notes.genesis_crdt_note(u, v, id, "B/Two.md")
    refute_enqueued(worker: Engram.Workers.EmbedNote)

    assert_zero_index_calls(fn -> {:ok, :already_moved} end)
  end

  # The web app moves notes through crdt_create (#1612).
  test "web-app move (crdt_create live relocate)", %{user: u, vault: v, ids: ids} do
    id = ids["A/Two.md"]
    assert_zero_index_calls(fn -> Notes.genesis_crdt_note(u, v, id, "B/Two.md") end)
  end
end
