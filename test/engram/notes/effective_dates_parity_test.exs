defmodule Engram.Notes.EffectiveDatesParityTest do
  @moduledoc """
  The note filter's date indexes read the effective date in SQL
  (`EffectiveDates.updated_sql/1` / `created_sql/1`: the stored date a
  content save derived, else the row time); the v5 payload computes it in
  Elixir (`EffectiveDates.updated/2` / `created/2` over
  `FlatFields.extract/2`). They must agree exactly on every note, or a date
  filter and a payload date disagree. And the migrated expression
  indexes must be built on exactly `index_sql/1`, or Postgres never uses them.
  """
  use Engram.DataCase, async: false

  alias Engram.Crypto
  alias Engram.Notes
  alias Engram.Notes.EffectiveDates
  alias Engram.Notes.FlatFields
  alias Engram.Notes.Note

  require EffectiveDates

  setup do
    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    %{user: user, vault: insert(:vault, user: user)}
  end

  @cases [
    {"no frontmatter, fractional file time", "body\n", %{"mtime" => 1_700_000_000.9}},
    {"only created", "---\ncreated: 2020-05-05\n---\nx\n", %{"mtime" => 1_600_000_000.0}},
    {"created under its alias date", "---\ndate: 2019-01-02\n---\nx\n", %{"mtime" => 5.0}},
    {"unparseable dates", "---\nupdated: not-a-date\ncreated: nope\n---\nx\n",
     %{"mtime" => 1_650_000_000.0, "ctime" => 1_640_000_000.5}},
    {"timezone offsets",
     "---\nupdated: 2026-01-01T10:00:00+05:30\ncreated: 2025-12-31T23:30:00-08:00\n---\nx\n",
     %{"mtime" => 1.0}},
    {"no file time: the row time", "---\ntitle: t\n---\nx\n", %{}},
    {"file time 0: the row time", "x\n", %{"mtime" => 0.0, "ctime" => 0.0}},
    {"updated wins over timestamp (v5, not OKF, order)",
     "---\ntimestamp: 2021-01-01\nupdated: 2022-02-02\n---\nx\n", %{"mtime" => 1.0}},
    {"capitalized keys", "---\nUpdated: 2023-03-03\nCreated: 2023-01-01\n---\nx\n",
     %{"mtime" => 1.0}},
    {"generated.at (strict, nested)", "---\ngenerated:\n  at: 2024-04-04T12:00:00Z\n---\nx\n",
     %{"mtime" => 1.0}},
    {"generated.at date-only is not a date", "---\ngenerated:\n  at: 2024-04-04\n---\nx\n",
     %{"mtime" => 3.0}},
    # What Obsidian writes for a datetime property: no seconds, no offset.
    # OKF's parser leaves `fm_created` NULL for both; the payload's reads them.
    {"Obsidian datetime, no seconds", "---\ncreated: 2024-01-01T10:00\n---\nx\n",
     %{"ctime" => 1000.0}},
    {"Obsidian datetime, no offset", "---\ncreated: 2024-01-01T10:00:00\n---\nx\n",
     %{"ctime" => 1000.0}},
    {"file times in milliseconds", "x\n",
     %{"mtime" => 1_793_442_859_572.0, "ctime" => 1_510_897_528_861.5}}
  ]

  for {{name, content, times}, i} <- Enum.with_index(@cases) do
    @tag content: content, times: times, path: "p#{i}.md"
    test "SQL == Elixir: #{name}", %{user: user, vault: vault} = ctx do
      attrs = Map.merge(%{"path" => ctx.path, "content" => ctx.content}, ctx.times)
      {:ok, saved} = Notes.upsert_note(user, vault, attrs, actor: "api")

      {:ok, {row, sql}} =
        Repo.with_tenant(user.id, fn ->
          Repo.one!(
            from(n in Note,
              where: n.id == ^saved.id,
              select: {n, {EffectiveDates.updated_sql(n), EffectiveDates.created_sql(n)}}
            )
          )
        end)

      {:ok, fk} = Crypto.dek_filter_key(Repo.get!(Engram.Accounts.User, user.id))
      flat = FlatFields.extract(ctx.content, fk)

      elixir =
        {elem(EffectiveDates.updated(row, flat.fm_updated), 0),
         elem(EffectiveDates.created(row, flat.fm_created), 0)}

      assert sql == elixir
      # The save derived its dates at its version (the backfill skips the row).
      assert row.eff_v == row.version
    end
  end

  test "the Obsidian datetime is the frontmatter's, not the file time", ctx do
    {:ok, saved} =
      Notes.upsert_note(
        ctx.user,
        ctx.vault,
        %{
          "path" => "o.md",
          "content" => "---\ncreated: 2024-01-01T10:00\n---\nx\n",
          "ctime" => 1000.0
        },
        actor: "api"
      )

    {:ok, sql} =
      Repo.with_tenant(ctx.user.id, fn ->
        Repo.one!(
          from(n in Note, where: n.id == ^saved.id, select: EffectiveDates.created_sql(n))
        )
      end)

    assert sql == DateTime.to_unix(~U[2024-01-01 10:00:00Z])
  end

  describe "file times (through Engram.FileTime)" do
    test "seconds truncated, milliseconds normalized, 0, negatives and out of range unknown" do
      assert EffectiveDates.stored(nil, 1_700_000_000.9) == 1_700_000_000
      assert EffectiveDates.stored(nil, 1_700_000_000_900.0) == 1_700_000_000
      assert EffectiveDates.stored(nil, nil) == nil
      assert EffectiveDates.stored(nil, 0.0) == nil
      # At or below 0 is unknown, as main's payload had it.
      assert EffectiveDates.stored(nil, -5.0) == nil
      assert EffectiveDates.stored(nil, 1.0e19) == nil
      assert EffectiveDates.stored(42, 1_700_000_000.0) == 42
    end

    # Prod 2026-11-05 holds millisecond mtimes; `trunc(mtime)` put them near
    # the year 58,000. The stored date and the payload now agree on seconds.
    test "a millisecond mtime filters and indexes as its second", ctx do
      {:ok, saved} =
        Notes.upsert_note(
          ctx.user,
          ctx.vault,
          %{"path" => "ms.md", "content" => "x\n", "mtime" => 1_793_442_859_572.0},
          actor: "api"
        )

      row = Repo.with_tenant!(ctx.user.id, fn -> Engram.Fixtures.raw_note!(saved.id) end)
      assert row.eff_updated == 1_793_442_859
      assert EffectiveDates.updated(row, nil) == {1_793_442_859, 1}
    end

    # The client boundary (REST) refuses these with a 422; behind it a save
    # never fails on one, and the date falls back to the row time.
    test "an out-of-range file time saves, with the row time", ctx do
      {:ok, saved} =
        Notes.upsert_note(
          ctx.user,
          ctx.vault,
          %{"path" => "big.md", "content" => "x\n", "mtime" => 1.0e19},
          actor: "api"
        )

      row = Repo.with_tenant!(ctx.user.id, fn -> Engram.Fixtures.raw_note!(saved.id) end)
      assert row.eff_updated == nil
      assert elem(EffectiveDates.updated(row, nil), 1) == 2
    end
  end

  # `notes.updated_at` / `created_at` move to timestamptz (`Engram.Repo.Utc`).
  # The indexes must survive that ALTER (an expression on the timestamp form
  # stops being IMMUTABLE and the ALTER fails), and the date must not move.
  test "the row-time fallback survives the timestamptz conversion", ctx do
    {:ok, saved} =
      Notes.upsert_note(ctx.user, ctx.vault, %{"path" => "t.md", "content" => "x\n"},
        actor: "api"
      )

    read = fn ->
      Repo.one!(
        from(n in Note,
          where: n.id == ^saved.id,
          select: {EffectiveDates.updated_sql(n), EffectiveDates.created_sql(n)}
        ),
        skip_tenant_check: true
      )
    end

    before = read.()

    {:error, :rolled_back} =
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL TimeZone = 'America/Los_Angeles'")

        for col <- ~w(updated_at created_at) do
          Repo.query!(
            "ALTER TABLE notes ALTER COLUMN #{col} TYPE timestamptz USING #{col} AT TIME ZONE 'UTC'"
          )
        end

        assert read.() == before
        Repo.rollback(:rolled_back)
      end)
  end

  # Postgres matches an expression index only to an identical expression:
  # the migrated indexes must be built on exactly `index_sql/1`.
  for {kind, index} <- [updated: "notes_eff_updated_live", created: "notes_eff_created_live"] do
    test "#{index} is built on EffectiveDates.index_sql(#{inspect(kind)})" do
      kind = unquote(kind)

      include = Enum.join(EffectiveDates.index_include(kind), ", ")

      Repo.query!("""
      CREATE INDEX parity_probe ON notes (vault_id, (#{EffectiveDates.index_sql(kind)}))
      INCLUDE (#{include}) WHERE deleted_at IS NULL AND kind = 'note'
      """)

      def_of = fn name ->
        %{rows: [[d]]} =
          Repo.query!("SELECT pg_get_indexdef(to_regclass($1::text))", ["public.#{name}"])

        String.replace(d, name, "IDX")
      end

      assert def_of.(unquote(index)) == def_of.("parity_probe")
    end
  end
end
