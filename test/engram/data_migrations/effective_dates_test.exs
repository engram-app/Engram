defmodule Engram.DataMigrations.EffectiveDatesTest do
  @moduledoc """
  The effective-dates backfill: a note whose `eff_v` is not its `version`
  (saved before the columns existed, or by a release without them since)
  gets the frontmatter dates the index pass stored in note_attrs and the
  stored effective dates; a note a save
  already derived is never touched.
  """
  use Engram.DataCase, async: false

  import Engram.FieldCatalogHelpers

  alias Engram.DataMigrations.EffectiveDates, as: Backfill
  alias Engram.Notes.Note
  alias Engram.Workers.DataMigrationsRunner

  setup do
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    %{user: user, vault: insert(:vault, user: user)}
  end

  defp set!(user, note, set) do
    Repo.with_tenant!(user.id, fn ->
      Repo.update_all(from(n in Note, where: n.id == ^note.id and n.kind == "note"), set: set)
    end)
  end

  defp dates(note) do
    Repo.one!(
      from(n in Note,
        where: n.id == ^note.id,
        select: {n.fm_updated, n.fm_created_s, n.eff_updated, n.eff_created, n.eff_v == n.version}
      ),
      skip_tenant_check: true
    )
  end

  defp run_until_done(n \\ 5) do
    Enum.reduce_while(1..n, nil, fn _, _ ->
      case Backfill.run_pass(batch: 10) do
        :done -> {:halt, :done}
        other -> {:cont, other}
      end
    end)
  end

  test "registered with the runner" do
    assert Backfill in DataMigrationsRunner.migrations()
  end

  test "derives underived notes from note_attrs; leaves derived ones alone", ctx do
    fm =
      write_indexed!(
        ctx.user,
        ctx.vault,
        "fm.md",
        "---\nupdated: 2020-06-01\ncreated: 2024-01-01T10:00\n---\nx\n"
      )

    bare = write_indexed!(ctx.user, ctx.vault, "bare.md", "x\n")
    saved = write_indexed!(ctx.user, ctx.vault, "saved.md", "---\nupdated: 2021-01-01\n---\nx\n")

    up = DateTime.to_unix(~U[2020-06-01 00:00:00Z])
    cr = DateTime.to_unix(~U[2024-01-01 10:00:00Z])
    # Precondition: the save derived them (`write_indexed!` sets mtime 1.0).
    assert dates(fm) == {up, cr, up, cr, true}

    # As a note saved before the columns existed.
    set!(ctx.user, fm,
      fm_updated: nil,
      fm_created_s: nil,
      eff_updated: nil,
      eff_created: nil,
      eff_v: nil
    )

    set!(ctx.user, bare, mtime: 1_700_000_000.5, eff_updated: nil, eff_v: nil)
    # Derived by a save: the backfill must not overwrite it.
    set!(ctx.user, saved, eff_updated: 42)

    assert run_until_done() == :done
    assert dates(fm) == {up, cr, up, cr, true}
    assert dates(bare) == {nil, nil, 1_700_000_000, nil, true}
    assert elem(dates(saved), 2) == 42
  end

  # A release without the columns saved the note: its version moved past
  # `eff_v`, so the row is underived again and the next pass recomputes it.
  test "a save by the previous release is revisited", ctx do
    note = write_indexed!(ctx.user, ctx.vault, "n.md", "---\nupdated: 2020-06-01\n---\nx\n")
    assert run_until_done() == :done

    set!(ctx.user, note, version: 7, eff_updated: 5)
    assert run_until_done() == :done

    assert dates(note) ==
             {DateTime.to_unix(~U[2020-06-01 00:00:00Z]), nil,
              DateTime.to_unix(~U[2020-06-01 00:00:00Z]), nil, true}
  end

  test "an empty table is done at once" do
    assert run_until_done(2) == :done
  end
end
