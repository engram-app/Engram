defmodule Engram.FileTimeTest do
  @moduledoc """
  The one file-time normalizer: a client epoch number (seconds, or
  milliseconds, both seen in prod) to the `*_at` timestamptz value.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Engram.FileTime

  test "seconds, fractional seconds and milliseconds give the same instant" do
    assert FileTime.to_at(1_776_072_500) == {:ok, ~U[2026-04-13 09:28:20.000000Z]}
    assert FileTime.to_at(1_776_072_500.928) == {:ok, ~U[2026-04-13 09:28:20.928000Z]}
    assert FileTime.to_at(1_776_072_500_928.0) == {:ok, ~U[2026-04-13 09:28:20.928000Z]}
  end

  test "rounds to the nearest microsecond: 2038's .404 is not stored as .403999" do
    assert FileTime.to_at(2_147_484_020.404) == {:ok, ~U[2038-01-19 03:20:20.404000Z]}
    assert FileTime.to_at(1_104_537_600.123) == {:ok, ~U[2005-01-01 00:00:00.123000Z]}
  end

  # Real prod `notes.mtime` values (2026-11): desktop Obsidian's
  # `stat.mtimeMs` carries sub-millisecond digits, which the plugin divides
  # by 1000. Five floored 1 us low on 0.74/0.75; the other seven agree.
  @prod_times [
    {1_792_507_938.5950112, 595_011},
    {1_792_374_456.8065336, 806_534},
    {1_792_355_282.670638, 670_638},
    {1_793_463_598.414629, 414_629},
    {1_792_348_622.2113965, 211_397},
    {1_793_434_092.091588, 91_588},
    {1_792_744_305.7469757, 746_976},
    {1_793_152_317.489393, 489_393},
    {1_793_392_404.6805549, 680_555},
    {1_792_152_782.1053593, 105_359},
    {1_793_152_881.2996936, 299_694},
    {1_793_504_975.8445764, 844_576}
  ]

  test "prod desktop mtimes round to the microsecond; old and new twins serve the double" do
    for {t, us} <- @prod_times do
      {:ok, at} = FileTime.to_at(t)
      assert {DateTime.to_unix(at), at.microsecond} == {trunc(t), {us, 6}}, inspect(t)

      floored = DateTime.from_unix!(floor(t * 1_000_000), :microsecond)
      assert FileTime.epoch(floored, t) === t, inspect(t)
      assert FileTime.epoch(at, t) === t, inspect(t)
    end

    moved =
      Enum.count(@prod_times, fn {t, us} -> floor(t * 1_000_000) |> rem(1_000_000) != us end)

    assert moved == 5
  end

  test "never rounds up across a whole second" do
    # The double just below 1_700_000_000: x 1e6 rounds to the next second
    # (the old floor crossed it too).
    t = 1_699_999_999.9999998
    assert t < 1_700_000_000
    {:ok, at} = FileTime.to_at(t)
    assert DateTime.to_unix(at) == trunc(t)
    assert at.microsecond == {999_999, 6}
    # Milliseconds: the same guard on the ms-to-us scale.
    t = 1_699_999_999_999.9998
    assert t < 1_700_000_000_000
    {:ok, at} = FileTime.to_at(t)
    assert DateTime.to_unix(at) == 1_699_999_999
  end

  test "the unit boundary: below 1e11 is seconds, at it is milliseconds" do
    assert {:ok, %DateTime{year: 5138}} = FileTime.to_at(99_999_999_999)
    assert {:ok, %DateTime{year: 1973}} = FileTime.to_at(100_000_000_000)
  end

  test "nil and 0 (the plugin's unknown) are NULL" do
    assert FileTime.to_at(nil) == {:ok, nil}
    assert FileTime.to_at(0) == {:ok, nil}
    assert FileTime.to_at(0.0) == {:ok, nil}
  end

  test "a time before 1970 in seconds is kept" do
    assert FileTime.to_at(-86_400) == {:ok, ~U[1969-12-31 00:00:00.000000Z]}
  end

  test "past year 9999 or before year 1 is out of range" do
    assert FileTime.to_at(1.0e19) == {:error, :out_of_range}
    assert FileTime.to_at(-1.0e19) == {:error, :out_of_range}
    # About year -7500 as milliseconds: Elixir takes it, Postgres would not.
    assert FileTime.to_at(-3.0e14) == {:error, :out_of_range}
    # Huge doubles would overflow the scaling: out of range, never a raise.
    assert FileTime.to_at(1.0e306) == {:error, :out_of_range}
    assert FileTime.to_at(Integer.pow(10, 400)) == {:error, :out_of_range}
    assert {:ok, %DateTime{year: 1}} = FileTime.to_at(-62_135_596_800)
    assert FileTime.to_at(-62_135_596_801) == {:error, :out_of_range}
  end

  # Floored, never rounded: a seconds value keeps its second, as
  # `trunc(mtime)` does (the payload hash depends on it).
  test "the second never rolls over" do
    for t <- [1_776_072_500.9999995, 1_776_072_500.999999, 1_700_000_000.9999999] do
      {:ok, at} = FileTime.to_at(t)
      assert DateTime.to_unix(at) == trunc(t), inspect(t)
    end

    # Rounded within its second (0.74 and 0.75 floored to 572_999).
    {:ok, at} = FileTime.to_at(1_793_442_859_572.9995)
    assert {DateTime.to_unix(at), at.microsecond} == {1_793_442_859, {573_000, 6}}
  end

  test "check/2: the first out-of-range number param, else :ok" do
    assert FileTime.check(%{"mtime" => 1.0, "ctime" => 1.0e19}, ~w(mtime ctime)) ==
             {:error, "ctime"}

    # Read as the double column's cast reads it: a numeric string counts.
    assert FileTime.check(%{"mtime" => "1.0e19"}, ~w(mtime)) == {:error, "mtime"}
    assert FileTime.check(%{"mtime" => "1.5"}, ~w(mtime)) == :ok
    assert FileTime.check(%{"mtime" => "soon"}, ~w(mtime)) == :ok
    # JSON `1e400` written out as an integer: past the largest double.
    assert FileTime.check(%{"mtime" => Integer.pow(10, 400)}, ~w(mtime)) == {:error, "mtime"}
    assert FileTime.check(%{}, ~w(mtime ctime)) == :ok
  end

  test "validate/2: an out-of-range change is an error" do
    cs =
      {%{}, %{mtime: :float}}
      |> Ecto.Changeset.cast(%{mtime: 1.0e19}, [:mtime])
      |> FileTime.validate(:mtime)

    assert cs.errors == [mtime: {"is out of range", []}]
  end

  test "put_at: sets the *_at field when the number changes; out of range is NULL" do
    types = %{mtime: :float, mtime_at: :utc_datetime_usec}

    cs = fn attrs ->
      {%{}, types} |> Ecto.Changeset.cast(attrs, [:mtime]) |> FileTime.put_at(:mtime, :mtime_at)
    end

    assert Ecto.Changeset.get_change(cs.(%{mtime: 1_700_000_000.5}), :mtime_at) ==
             ~U[2023-11-14 22:13:20.500000Z]

    assert Ecto.Changeset.get_change(cs.(%{mtime: 1_700_000_000_500.0}), :mtime) ==
             1_700_000_000_500.0

    refute Ecto.Changeset.changed?(cs.(%{}), :mtime_at)

    # A write that carries an unchanged double heals a stale twin.
    heal = fn data, attrs ->
      {data, types} |> Ecto.Changeset.cast(attrs, [:mtime]) |> FileTime.put_at(:mtime, :mtime_at)
    end

    stale = %{mtime: 1_700_000_000.5, mtime_at: ~U[2000-01-01 00:00:00.000000Z]}

    assert Ecto.Changeset.get_change(heal.(stale, %{}), :mtime_at) ==
             ~U[2023-11-14 22:13:20.500000Z]

    assert Ecto.Changeset.get_change(heal.(stale, %{mtime: 1_700_000_000.5}), :mtime_at) ==
             ~U[2023-11-14 22:13:20.500000Z]

    ok = %{mtime: 1_700_000_000.5, mtime_at: ~U[2023-11-14 22:13:20.500000Z]}
    refute Ecto.Changeset.changed?(heal.(ok, %{}), :mtime_at)
    refute Ecto.Changeset.changed?(heal.(%{mtime: nil, mtime_at: nil}, %{}), :mtime_at)

    # A stored legacy value a server-side copy carries: never a refused write.
    bad = cs.(%{mtime: 1.0e19})
    assert bad.valid?
    assert Ecto.Changeset.get_field(bad, :mtime_at) == nil
  end

  test "normalize/1 is to_at/1 with out of range as NULL; same_at?/2 compares instants" do
    assert FileTime.normalize(1_776_072_500_928.0) == ~U[2026-04-13 09:28:20.928000Z]
    assert FileTime.normalize(1.0e19) == nil
    assert FileTime.normalize(0) == nil
    assert FileTime.same_at?(nil, nil)
    assert FileTime.same_at?(~U[2026-01-01 00:00:00Z], ~U[2026-01-01 00:00:00.000000Z])
    refute FileTime.same_at?(nil, ~U[2026-01-01 00:00:00Z])
    refute FileTime.same_at?(~U[2026-01-01 00:00:00Z], ~U[2026-01-01 00:00:01Z])
  end

  describe "epoch/2 and mtime/1, the readers' wire value" do
    test "a seconds double that normalizes to the timestamp is sent bit-identical" do
      for t <- [1_776_072_500.9, 1_776_072_500.928, 1_700_000_000.0, 1.0, -86_400.5] do
        {:ok, at} = FileTime.to_at(t)
        assert FileTime.epoch(at, t) === t
      end
    end

    test "milliseconds go out as seconds, normalized from the double" do
      {:ok, at} = FileTime.to_at(1_776_072_500_928.0)
      assert FileTime.epoch(at, 1_776_072_500_928.0) === 1_776_072_500.928
      # Before the backfill reaches the row.
      assert FileTime.epoch(nil, 1_776_072_500_928.0) === 1_776_072_500.928
    end

    # The read switch: the twin is served whenever present.
    test "a stale timestamp is served over the double" do
      stale = ~U[2026-04-13 09:28:20.500000Z]
      assert FileTime.epoch(stale, 1.0) === 1_776_072_500.5
      assert FileTime.epoch(stale, 1_776_072_500_928.0) === 1_776_072_500.5
    end

    # The contract shape (no double): the twin alone must give back the
    # millisecond-precision seconds the client sent. Floored, about a
    # quarter of 2004-2005 and post-2038-01-19 values came back 1 us low.
    property "the twin alone round-trips millisecond-precision seconds, 1970-2071" do
      check all(
              s <-
                one_of([
                  integer(0..3_155_760_000),
                  integer(1_073_741_824..1_125_899_906),
                  integer(2_147_483_648..3_155_760_000)
                ]),
              ms <- integer(0..999),
              max_runs: 5_000
            ) do
        t = s + ms / 1_000
        assert FileTime.epoch(FileTime.normalize(t), nil) === t
      end
    end

    test "a v1 floored twin (1 us low) still agrees: the double goes out" do
      t = 2_147_484_020.404
      floored = DateTime.add(FileTime.normalize(t), -1, :microsecond)
      assert FileTime.twin?(floored, t)
      assert FileTime.epoch(floored, t) === t
      refute FileTime.twin?(DateTime.add(floored, -1, :microsecond), t)
      refute FileTime.twin?(DateTime.add(FileTime.normalize(t), 2, :microsecond), t)
      refute FileTime.twin?(nil, t)
      refute FileTime.twin?(floored, nil)
    end
  end
end
