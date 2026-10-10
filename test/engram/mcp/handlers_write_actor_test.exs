defmodule Engram.MCP.HandlersWriteActorTest do
  @moduledoc """
  Every MCP note write must record as actor "mcp", or an AI edit merges into
  the user's own version and "undo just the AI's change" stops working (#1710).
  """
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Engram.MCP.Handlers
  alias Engram.{Notes, Repo}
  alias Engram.Notes.Revision

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "MCP Actor", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  test "write_note records as mcp", %{user: u, vault: v} do
    {:ok, note} = Notes.upsert_note(u, v, %{"path" => "m.md", "content" => "mine"}, actor: "api")

    Handlers.handle("write_note", u, v, %{"path" => "m.md", "content" => "the AI's"})

    {:ok, open} =
      Repo.with_tenant(u.id, fn ->
        Repo.one(from(r in Revision, where: r.note_id == ^note.id and is_nil(r.closed_at)))
      end)

    assert %Revision{actor: "mcp"} = open
  end

  # A new MCP write tool that forgets the actor would silently default to
  # "api". Every upsert/rmw call in the handlers module must carry @write_opts.
  test "every upsert_note call in Handlers passes the mcp actor" do
    source = File.read!("lib/engram/mcp/handlers.ex")
    calls = length(Regex.scan(~r/Notes\.(upsert_note|rmw_note)\(/, source))
    with_actor = length(Regex.scan(~r/@write_opts\s*\)/, source))

    assert calls > 0
    assert calls == with_actor
  end
end
