defmodule Engram.Insights.SnapshotNarrowTest do
  @moduledoc """
  #2411: the daily snapshot and the PostHog person sync take note counts and
  stored bytes from the narrow, trigger-kept `note_index_state` rows once
  `NoteSizes` is done, instead of aggregating every live `notes` row.
  """
  use Engram.DataCase, async: false

  alias Engram.Analytics.PersonProperties
  alias Engram.DataMigrations
  alias Engram.DataMigrations.NoteSizes
  alias Engram.Insights.Snapshot
  alias Engram.Notes
  alias Engram.QueryRecorder
  alias Engram.Repo

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Snap", Ecto.UUID.generate())

    notes =
      for i <- 1..3 do
        {:ok, n} =
          Notes.upsert_note(user, vault, %{"path" => "s#{i}.md", "content" => "body #{i}"},
            actor: "api"
          )

        n
      end

    %{user: user, vault: vault, notes: notes}
  end

  defp traits(user_id), do: PersonProperties.by_user() |> Map.new() |> Map.fetch!(user_id)
  defp done!, do: DataMigrations.mark_done(NoteSizes.name(), NoteSizes.version())

  # Red before: PersonProperties grouped every live notes row (the daily
  # PostHog sync and the snapshot both call it).
  test "person facts: same counts and bytes, no notes aggregate", %{user: u} do
    wide = traits(u.id)
    done!()
    {narrow, queries} = QueryRecorder.record(fn -> traits(u.id) end)

    assert Map.take(narrow, [:total_notes, :total_note_bytes]) ==
             Map.take(wide, [:total_notes, :total_note_bytes])

    refute Enum.any?(queries, &(&1.sql =~ ~s(FROM "notes") and &1.sql =~ "count(")),
           "still aggregates notes"
  end

  # Red before: an unchanged vault's row was copied with yesterday's bytes,
  # and only a weekly rescan of every note corrected a byte change that moved
  # no seq (a re-encode).
  test "a copied vault takes fresh bytes without a rescan", %{vault: v, notes: [n | _]} do
    done!()
    day1 = Date.add(Date.utc_today(), -2)
    Snapshot.run(day: day1)

    Repo.query!(
      "UPDATE note_bodies SET content_ct = content_ct || '\\\\x0102030405'::bytea WHERE note_id = $1",
      [Ecto.UUID.dump!(n.id)]
    )

    Snapshot.run(day: Date.add(day1, 1))

    %{rows: [[b1], [b2]]} =
      Repo.query!(
        "SELECT note_bytes FROM vault_daily_metrics WHERE vault_id = $1 ORDER BY date",
        [Ecto.UUID.dump!(v.id)]
      )

    %{rows: [[raw]]} =
      Repo.query!("SELECT sum(octet_length(content_ct) - 13)::bigint FROM note_bodies")

    assert b2 > b1
    assert b2 == raw
  end
end
