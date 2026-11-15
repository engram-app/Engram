defmodule Engram.Links.ReadTimeLinksPlanTest do
  # The read-time outgoing links (`Links.links_for_notes/2` given a note's
  # text) as prod runs them: `engram_app`, FORCE RLS, the tenant set by the
  # read itself, 8 calls on one connection (past the 5 custom plans Postgres
  # tries before a named statement may go generic).
  #
  # The read-time path adds no SQL shape: it skips the `note_links` read and
  # sends the same candidate union and note-path read as the stored path. So
  # this pins (1) the answer under RLS on every call, (2) no `note_links`
  # read, (3) the union is never a named statement, so never a generic plan (see
  # `target_candidates_plan_test.exs` and notes-generic-plan-mis-pick.md for
  # why its generic plan walks the vault), and (4) its custom plan, read as
  # `engram_app` with the tenant set, uses an index for every `notes` part.
  # Not async: ALTER TABLE and the role drop.
  use Engram.DataCase, async: false

  import Ecto.Query
  import Engram.RlsCase

  alias Engram.Fixtures
  alias Engram.Links
  alias Engram.Links.Parser
  alias Engram.Notes
  alias Engram.QueryPlan

  @union ~r/FROM "notes".*UNION ALL/s

  setup do
    {:ok, user} = Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)

    for path <- ["Target.md", "Folder/Deep.md", "Deep.md", "Old.md"] do
      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => path, "content" => "x", "mtime" => 1.0},
          actor: "api"
        )
    end

    text = "[[Target]] [[Folder/Deep]] [[Ghost]]"

    {:ok, src} =
      Notes.upsert_note(user, vault, %{"path" => "Source.md", "content" => text, "mtime" => 1.0},
        actor: "api"
      )

    # Stale stored rows: a read that used them would answer `Old`.
    :ok = Links.replace_links(user, vault, src.id, Parser.extract("[[Old]]"))
    {:ok, note} = Notes.get_note(user, vault, "Source.md")

    for table <- ~w(notes attachments),
        col <- ~w(user_id vault_id),
        do: Repo.query!("ALTER TABLE #{table} ALTER COLUMN #{col} SET (n_distinct = 40)")

    QueryPlan.fresh!("notes")
    QueryPlan.fresh!("attachments")

    %{user: user, note: note}
  end

  defp prepared?(sql),
    do: Repo.query!("SELECT 1 FROM pg_prepared_statements WHERE statement = $1", [sql]).rows != []

  # The SQL of a user-wide notes count, run (named) on this connection.
  defp named_sql(user) do
    me = self()

    {_, queries} =
      Engram.QueryRecorder.record(fn ->
        Repo.one(
          from(n in Notes.Note, where: n.user_id == ^user.id, select: count()),
          skip_tenant_check: true
        )
      end)

    queries |> Enum.find(&(&1.pid == me and &1.sql =~ ~s(FROM "notes"))) |> Map.fetch!(:sql)
  end

  test "as engram_app: right on every call, no note_links read, union never generic",
       %{user: user, note: note} do
    me = self()

    recorded =
      for _ <- 1..8 do
        {{:returned, links}, queries} =
          Engram.QueryRecorder.record(fn ->
            as_prod_role(fn -> Links.links_for_note(user, note) end)
          end)

        assert Enum.map(links, &{&1.target_text, &1.target_path, &1.dangling}) == [
                 {"Target", "Target.md", false},
                 {"Folder/Deep", "Folder/Deep.md", false},
                 {"Ghost", nil, true}
               ]

        mine = Enum.filter(queries, &(&1.pid == me))
        assert Enum.filter(mine, &(&1.sql =~ ~s("note_links"))) == []
        mine |> Enum.filter(&(&1.sql =~ @union)) |> List.last()
      end
      |> List.last()
      |> Kernel.||(flunk("the read-time path sent no candidate union"))

    # Positive control, same connection: a named notes query is found by
    # the lookup below. Without it, a lookup that could never match the
    # recorded SQL would pass the refute.
    named = named_sql(user)
    assert prepared?(named), "the lookup cannot see a named statement:\n#{named}"

    refute prepared?(recorded.sql),
           "the union is a named prepared statement, so it can go generic:\n#{recorded.sql}"

    %{custom: custom} = QueryPlan.rls_plans(user.id, recorded.sql, recorded.params)
    refute custom =~ ~r/Seq Scan on notes/, "custom plan:\n#{custom}"
  end
end
