defmodule Engram.Indexing.PayloadV5FileTimeTest do
  @moduledoc """
  R25 migrate-data: `PayloadV5` reads the file times through
  `Engram.FileTime` (`mtime_at` / `ctime_at`). For every seconds-unit note
  the payload, and so its hash, must stay bit-identical to the formula on
  main before the switch (a changed hash rewrites the note's points): only
  millisecond notes change, once.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Engram.FileTime
  alias Engram.Indexing
  alias Engram.Indexing.PayloadV5
  alias Engram.Notes.FlatFields
  alias Engram.Notes.Note

  @hour 3_600

  # Main's fallbacks before the switch, on the double alone.
  defp old_up(%{mtime: t}) when is_number(t) and t > 0, do: {ceil(t / @hour) * @hour, 1}
  defp old_up(note), do: {ceil(DateTime.to_unix(note.updated_at) / @hour) * @hour, 2}
  defp old_cr(%{ctime: t}) when is_number(t) and t > 0, do: {trunc(t), 1}
  defp old_cr(note), do: {DateTime.to_unix(note.created_at), 2}

  defp old_payload(note) do
    {up, us} = old_up(note)
    {cr, cs} = old_cr(note)

    p =
      PayloadV5.build(
        %{note | mtime: nil, ctime: nil, mtime_at: nil, ctime_at: nil},
        FlatFields.empty()
      )

    p |> Map.merge(%{"up" => up, "cr" => cr}) |> put_src("us", us) |> put_src("cs", cs)
  end

  defp put_src(p, k, src), do: Map.put(p, k, src)

  defp note(mtime, ctime) do
    %Note{
      id: Ecto.UUID.generate(),
      user_id: Ecto.UUID.generate(),
      vault_id: Ecto.UUID.generate(),
      path_hmac: <<1::256>>,
      folder_hmac: <<2::256>>,
      tags_hmac: [],
      mtime: mtime,
      ctime: ctime,
      mtime_at: FileTime.to_at!(mtime),
      ctime_at: FileTime.to_at!(ctime),
      created_at: ~U[2026-01-01 00:00:00.000000Z],
      updated_at: ~U[2026-01-02 00:00:00.000000Z]
    }
  end

  # Seconds as clients send them: whole, fractional (ms and sub-ms digits),
  # exact hours and just past one, 0 (unknown), before 1970, nil.
  defp seconds do
    one_of([
      integer(-2_000_000_000..4_000_000_000) |> map(&(&1 * 1.0)),
      tuple({integer(0..4_000_000_000), integer(0..999_999)})
      |> map(fn {s, us} -> s + us / 1_000_000 end),
      integer(0..1_000_000) |> map(&(&1 * @hour * 1.0)),
      integer(0..1_000_000) |> map(&(&1 * @hour + 1.0e-6)),
      float(min: 0.0, max: 9.9e10),
      constant(0.0),
      constant(nil)
    ])
  end

  property "seconds notes: payload and payload hash equal main's" do
    check all(mtime <- seconds(), ctime <- seconds(), max_runs: 2_000) do
      n = note(mtime, ctime)
      new = PayloadV5.build(n, FlatFields.empty())
      old = old_payload(n)
      assert new == old
      assert Indexing.note_payload_hash(new) == Indexing.note_payload_hash(old)
    end
  end

  test "a millisecond note reads as its seconds instant" do
    ms = note(1_776_072_500_928.0, 1_510_897_528_861.0)
    s = note(1_776_072_500.928, 1_510_897_528.861)
    dates = &Map.take(PayloadV5.build(&1, FlatFields.empty()), ~w(up us cr cs))
    assert dates.(ms) == dates.(s)
  end

  test "before the backfill (NULL *_at) the double is read as on main" do
    n = %{note(1_776_072_500.928, 5.5) | mtime_at: nil, ctime_at: nil}
    assert PayloadV5.build(n, FlatFields.empty()) == old_payload(n)
  end

  test "a drifted twin: the seconds double wins, payload and stored date agree" do
    n = %{note(1_776_072_500.928, 1_510_897_528.861) | mtime_at: ~U[2020-01-01 00:00:00Z]}
    p = PayloadV5.build(n, FlatFields.empty())
    assert p == old_payload(n)
    {stored, 1} = Engram.Notes.EffectiveDates.updated(n, nil)
    assert stored == trunc(n.mtime)
    assert p["up"] == ceil(stored / @hour) * @hour
  end

  test "the contract shape (no double, *_at set) ceils the twin" do
    n = %{note(1_776_072_500.928, 5.5) | mtime: nil}
    assert %{"up" => up, "us" => 1} = PayloadV5.build(n, FlatFields.empty())
    assert up == ceil(1_776_072_500.928 / @hour) * @hour
  end
end
