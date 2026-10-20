defmodule Engram.Notes.FrontmatterAttrsTest do
  use ExUnit.Case, async: true

  alias Engram.Notes.FrontmatterAttrs
  alias Engram.Vector.FilterId

  @fk :crypto.strong_rand_bytes(32)

  defp extract(values), do: FrontmatterAttrs.extract(values, @fk)
  defp k(key), do: FilterId.key_hmac(@fk, key)
  defp v(value), do: FilterId.value_hmac(@fk, value)

  test "strings and booleans are exact attrs, numbers and dates are ranges" do
    got =
      extract(%{
        "mood" => "calm",
        "done" => true,
        "rating" => 4.5,
        "count" => 3,
        "launch" => "2026-11-01",
        "at" => "2026-11-01T10:00:00Z"
      })

    assert Enum.sort(got.attrs) ==
             Enum.sort([%{k: k("mood"), v: v("calm")}, %{k: k("done"), v: v("true")}])

    assert Enum.sort(got.nums) == Enum.sort([%{k: k("rating"), n: 4.5}, %{k: k("count"), n: 3.0}])

    assert Enum.sort(got.dates) ==
             Enum.sort([
               %{k: k("launch"), t: DateTime.to_unix(~U[2026-11-01 00:00:00Z])},
               %{k: k("at"), t: DateTime.to_unix(~U[2026-11-01 10:00:00Z])}
             ])
  end

  test "first-class keys, their aliases and the prefix keys never appear" do
    values =
      Map.new(
        ~w(type tags status author reviewed_by source resource sources project created
           date updated modified timestamp reviewed expires stale_after due priority title
           aliases description verified generated),
        &{&1, "x"}
      )

    assert extract(values) == %{attrs: [], nums: [], dates: []}
  end

  test "a nested map is skipped, not flattened" do
    assert extract(%{"meta" => %{"a" => 1}}) == %{attrs: [], nums: [], dates: []}

    assert extract(%{"generated" => %{"by" => "human:x", "at" => "2026-01-01T00:00:00Z"}}) ==
             %{attrs: [], nums: [], dates: []}
  end

  test "a list gives one entry per scalar element" do
    got = extract(%{"colors" => ["red", "blue", %{"x" => 1}]})
    assert got.attrs == [%{k: k("colors"), v: v("red")}, %{k: k("colors"), v: v("blue")}]
  end

  test "a list keeps at most 64 elements" do
    got = extract(%{"many" => Enum.map(1..70, &"v#{&1}")})
    assert length(got.attrs) == 64
  end

  test "a string over 256 bytes is skipped" do
    assert extract(%{"blob" => String.duplicate("a", 300)}).attrs == []
    assert length(extract(%{"ok" => String.duplicate("a", 256)}).attrs) == 1
  end

  test "70 keys keep 64 entries" do
    got = extract(Map.new(1..70, &{"key#{&1}", "v"}))
    assert length(got.attrs) == 64
  end

  test "nil and empty strings store nothing" do
    assert extract(%{"a" => nil, "b" => ""}) == %{attrs: [], nums: [], dates: []}
  end
end
