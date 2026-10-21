defmodule Engram.Notes.FrontmatterDateTest do
  use ExUnit.Case, async: true

  alias Engram.Notes.FrontmatterDate

  defp unix(dt), do: DateTime.to_unix(dt)

  test "a bare date is midnight UTC on that day (lenient only)" do
    assert FrontmatterDate.parse("2026-11-01", :lenient) ==
             {unix(~U[2026-11-01 00:00:00Z]), ~D[2026-11-01]}

    assert FrontmatterDate.parse("2026-11-01", :strict) == nil
  end

  test "Obsidian datetime forms: no seconds, no offset, space separator" do
    for v <- [
          "2026-11-01T10:00",
          "2026-11-01T10:00:00",
          "2026-11-01 10:00",
          "2026-11-01 10:00:00"
        ] do
      assert FrontmatterDate.parse(v, :lenient) ==
               {unix(~U[2026-11-01 10:00:00Z]), ~D[2026-11-01]},
             v
    end
  end

  test "with an offset or Z, the instant converts and the day stays the written one" do
    assert FrontmatterDate.parse("2026-11-01T23:00-08:00", :lenient) ==
             {unix(~U[2026-11-02 07:00:00Z]), ~D[2026-11-01]}

    assert FrontmatterDate.parse("2026-11-01T23:00Z", :strict) ==
             {unix(~U[2026-11-01 23:00:00Z]), ~D[2026-11-01]}

    assert FrontmatterDate.parse("2026-11-01 23:00:30+02:00", :strict) ==
             {unix(~U[2026-11-01 21:00:30Z]), ~D[2026-11-01]}
  end

  test "strict needs an offset" do
    assert FrontmatterDate.parse("2026-11-01T10:00", :strict) == nil
  end

  test "garbage and non-strings are nil" do
    for v <- ["soon", "2026-13-01", "2026-11-01T25:00", "2026-11-01Tnope", 42, nil, true] do
      assert FrontmatterDate.parse(v, :lenient) == nil, inspect(v)
    end
  end

  test "day numbers count from 1970-01-01" do
    assert FrontmatterDate.day(~D[2026-11-01]) == 20_758
    assert FrontmatterDate.day(~D[1969-12-31]) == -1
  end
end
