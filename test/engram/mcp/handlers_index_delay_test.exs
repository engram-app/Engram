defmodule Engram.MCP.HandlersIndexDelayTest do
  @moduledoc """
  #2294: an AI agent writes a note over MCP and searches for it seconds later.
  Search is filled by the debounced EmbedNote job, so MCP writes must schedule
  it within seconds, while plugin/web writes keep the full typing debounce.
  Both kinds of write share ONE unique job per note: whichever write came last
  sets the timer, and there is never a second job.
  """
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Engram.MCP.Handlers
  alias Engram.{Notes, Repo}
  alias Engram.Workers.EmbedNote

  setup do
    for {key, val} <- [embed_settle_seconds: 30, embed_agent_settle_seconds: 2] do
      prev = Application.get_env(:engram, key)
      Application.put_env(:engram, key, val)

      on_exit(fn ->
        if is_nil(prev),
          do: Application.delete_env(:engram, key),
          else: Application.put_env(:engram, key, prev)
      end)
    end

    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Index Delay", Ecto.UUID.generate())
    # Only the jobs the test's own writes enqueue.
    Repo.delete_all(Oban.Job)
    %{user: user, vault: vault}
  end

  defp embed_jobs do
    Repo.all(from(j in Oban.Job, where: j.worker == "Engram.Workers.EmbedNote"))
  end

  defp seconds_out(%Oban.Job{scheduled_at: at}), do: DateTime.diff(at, DateTime.utc_now())

  defp plugin_write(u, v, path, content),
    do: {:ok, _} = Notes.upsert_note(u, v, %{"path" => path, "content" => content}, actor: "sync")

  defp mcp_write(u, v, path, content),
    do: {:ok, _, _} = Handlers.handle("write_note", u, v, %{"path" => path, "content" => content})

  test "an MCP create schedules indexing within seconds", %{user: u, vault: v} do
    {:ok, _, _} =
      Handlers.handle("create_note", u, v, %{
        "title" => "fresh",
        "suggested_folder" => "Inbox",
        "content" => "agent wrote this"
      })

    assert [job] = embed_jobs()
    assert seconds_out(job) <= EmbedNote.agent_settle_seconds() + 1
  end

  test "a plugin write keeps the full settle debounce", %{user: u, vault: v} do
    plugin_write(u, v, "p.md", "typing")

    assert [job] = embed_jobs()
    assert seconds_out(job) in 25..30
  end

  test "repeated MCP writes to one note coalesce into one job", %{user: u, vault: v} do
    mcp_write(u, v, "m.md", "one")
    mcp_write(u, v, "m.md", "two")
    mcp_write(u, v, "m.md", "three")

    assert [job] = embed_jobs()
    assert seconds_out(job) <= EmbedNote.agent_settle_seconds() + 1
  end

  test "a plugin edit after an MCP write is not shortened", %{user: u, vault: v} do
    mcp_write(u, v, "x.md", "agent")
    plugin_write(u, v, "x.md", "then the user types")

    assert [job] = embed_jobs()
    assert seconds_out(job) in 25..30
  end

  test "an MCP write after a plugin edit pulls the one job in", %{user: u, vault: v} do
    plugin_write(u, v, "y.md", "user typed")
    mcp_write(u, v, "y.md", "agent rewrote")

    assert [job] = embed_jobs()
    assert seconds_out(job) <= EmbedNote.agent_settle_seconds() + 1
  end

  test "every MCP write reply tells the agent when search will see it", %{user: u, vault: v} do
    {:ok, text, _} =
      Handlers.handle("write_note", u, v, %{"path" => "r.md", "content" => "body"})

    assert text =~ Handlers.index_delay_hint()
    assert text =~ "get_notes"

    {:ok, text, _} =
      Handlers.handle("append_to_note", u, v, %{"path" => "r.md", "content" => "more"})

    assert text =~ Handlers.index_delay_hint()
  end
end
