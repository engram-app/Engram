defmodule Engram.FileTimeTest do
  @moduledoc """
  The one file-time normalizer: a client epoch number (seconds, or
  milliseconds, both seen in prod) to the `*_at` timestamptz value.
  """
  use ExUnit.Case, async: true

  alias Engram.FileTime

  test "seconds, fractional seconds and milliseconds give the same instant" do
    assert FileTime.to_at(1_776_072_500) == {:ok, ~U[2026-04-13 09:28:20.000000Z]}
    assert FileTime.to_at(1_776_072_500.928) == {:ok, ~U[2026-04-13 09:28:20.928000Z]}
    assert FileTime.to_at(1_776_072_500_928.0) == {:ok, ~U[2026-04-13 09:28:20.928000Z]}
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

    {:ok, at} = FileTime.to_at(1_793_442_859_572.9995)
    assert at.microsecond == {572_999, 6}
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

    # During migrate-data every release writes the double and the twin is
    # derived from it, so a disagreement means the twin is stale.
    test "the double wins over a stale timestamp" do
      stale = ~U[2026-04-13 09:28:20.500000Z]
      assert FileTime.epoch(stale, 1.0) === 1.0
      assert FileTime.epoch(stale, 1_776_072_500_928.0) === 1_776_072_500.928
    end

    test "the timestamp stands alone only without a double (after contract)" do
      assert FileTime.epoch(~U[2026-04-13 09:28:20.500000Z], nil) === 1_776_072_500.5
      assert FileTime.epoch(nil, nil) == nil
    end

    test "0 and out of range go out as stored" do
      assert FileTime.epoch(nil, 1_776_072_500.9) === 1_776_072_500.9
      assert FileTime.epoch(nil, 0.0) === 0.0
      assert FileTime.epoch(nil, 1.0e19) === 1.0e19
      assert FileTime.epoch(~U[2020-01-01 00:00:00Z], 1.0e19) === 1.0e19
    end

    test "mtime/1 and ctime/1 read a row or a map" do
      row = %{mtime: 1_776_072_500_928.0, mtime_at: ~U[2026-04-13 09:28:20.928000Z], ctime: 5.0}
      assert FileTime.mtime(row) === 1_776_072_500.928
      assert FileTime.ctime(row) === 5.0
      assert FileTime.mtime(%{mtime: 2.0}) === 2.0
    end

    test "no time at all reads as nil, never false (a false would reach payloads)" do
      assert FileTime.epoch(nil, nil) === nil
      assert FileTime.mtime(%{mtime: nil, mtime_at: nil}) === nil
      assert FileTime.mtime(%{}) === nil
      assert FileTime.epoch(false, nil) === nil
    end
  end
end
