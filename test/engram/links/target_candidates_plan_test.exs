defmodule Engram.Links.TargetCandidatesPlanTest do
  # The link-target union (`Links.target_candidates/4`, behind
  # `links_for_note/2`, `backlinks_for_note/3` and the extract-links writer)
  # stays UNNAMED (a custom plan per call, never a cached generic one), and
  # sends only the parts its keys can match.
  #
  # Why unnamed, measured 2026-11-12 (`docs/context/notes-generic-plan-mis-pick.md`):
  # with `prepare: :named` the union went generic after 5 calls, and at
  # the 11-02 tenancy shape (`n_distinct = 40` on notes/attachments
  # user_id + vault_id, run as `engram_app` with the tenant set, seq scans
  # allowed) its generic plan read, per part:
  #
  #   notes stale        notes_user_vault_live (user_id, vault_id);
  #                      `basename_id = ANY($3)` only a row filter
  #   notes pathed       notes_path_ci (the key index)
  #   notes shortest x2  notes_user_vault_live, same
  #   attachments stale  attachments_link_keys_stale_index (the key index)
  #   attachments pathed, shortest x2: attachments_user_live_size
  #                      (user_id, vault_id), keys only row filters
  #
  # (HMAC mode: all four notes scans on notes_user_vault_live.) That is the
  # 11-02 mis-pick (`NotesGenericPlanTest`): a whole-vault walk per call on a
  # hub vault. Planning cost does not justify it; do not add `:named` back.
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Engram.DataMigrations
  alias Engram.Fixtures
  alias Engram.Links
  alias Engram.Links.Parser
  alias Engram.Notes
  alias Engram.Repo

  @union ~r/FROM "notes".*UNION ALL/s

  setup do
    on_exit(fn ->
      Engram.Cache.clear_local(:note_split)
      DataMigrations.reset_cache()
    end)

    {:ok, user} = Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)

    paths = ["F1/index.md", "F2/index.md", "Hub/index.md", "A/one.md", "zz/Source.md"]
    src = user |> Fixtures.insert_notes!(vault, Enum.map(paths, &%{path: &1})) |> List.last()
    Fixtures.insert_attachments!(user, vault, [%{path: "img.png"}])

    %{user: user, vault: vault, src: src}
  end

  defp ids_mode(on?) do
    if on?, do: :ok = DataMigrations.mark_done("note_split", 1)
    Engram.Cache.clear_local(:note_split)
    assert Notes.Keys.ids?() == on?
  end

  # The union `links_for_note/2` sends for a note whose body is `text`, after
  # 8 calls on this connection (past the 5 custom plans Postgres tries before
  # it may switch a named statement to a generic one).
  defp union_sql(%{user: u, vault: v, src: src}, text) do
    :ok = Links.replace_links(u, v, src, Parser.extract(text))
    me = self()

    Enum.reduce(1..8, nil, fn _, _ ->
      {_, queries} = Engram.QueryRecorder.record(fn -> Links.links_for_note(u, src) end)
      queries |> Enum.filter(&(&1.pid == me and &1.sql =~ @union)) |> List.last()
    end)
    |> Kernel.||(flunk("links_for_note/2 sent no candidate union"))
    |> Map.fetch!(:sql)
  end

  defp prepared?(sql),
    do: Repo.query!("SELECT 1 FROM pg_prepared_statements WHERE statement = $1", [sql]).rows != []

  # The SQL of a vault-wide notes count, run (named) on this connection.
  defp named_sql(vault) do
    me = self()

    {_, queries} =
      Engram.QueryRecorder.record(fn ->
        Repo.one(
          from(n in Notes.Note, where: n.vault_id == ^vault.id, select: count()),
          skip_tenant_check: true
        )
      end)

    queries |> Enum.find(&(&1.pid == me and &1.sql =~ ~s(FROM "notes"))) |> Map.fetch!(:sql)
  end

  for ids? <- [true, false] do
    describe "ids mode #{ids?}" do
      setup ctx do
        ids_mode(unquote(ids?))
        ctx
      end

      test "the union stays an unnamed statement", ctx do
        sql = union_sql(ctx, "[[index]] [[one]] [[img.png]] [[Hub/index]]")

        # Positive control, same connection: a notes query with no key compare
        # is named, and the lookup finds it by its recorded SQL. Without it, a
        # lookup that could never match would pass the refute below.
        named = named_sql(ctx.vault)
        assert prepared?(named), "the lookup cannot see a named statement:\n#{named}"

        refute prepared?(sql),
               "the candidate union is a named prepared statement, so it can go generic:\n#{sql}"
      end

      test "a bare-names call sends no pathed part", ctx do
        sql = union_sql(ctx, "[[index]] [[one]] [[img.png]]")
        refute sql =~ "path_ci_", sql
        assert sql =~ "min(", sql
      end

      test "a folder-qualified-only call sends no shortest part", ctx do
        sql = union_sql(ctx, "[[Hub/index]] [[A/one]]")
        refute sql =~ "min(", sql
        assert sql =~ "path_ci_", sql
      end
    end
  end
end
