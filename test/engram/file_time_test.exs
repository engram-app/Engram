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

    # A stored legacy value a server-side copy carries: never a refused write.
    bad = cs.(%{mtime: 1.0e19})
    assert bad.valid?
    assert Ecto.Changeset.get_field(bad, :mtime_at) == nil
  end
end
