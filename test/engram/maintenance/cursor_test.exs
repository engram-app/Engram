defmodule Engram.Maintenance.CursorTest do
  use Engram.DataCase, async: true

  alias Engram.Maintenance.Cursor

  test "a full run stores its last key, a short run wraps to the start" do
    assert Cursor.get("t") == nil
    :ok = Cursor.advance("t", %{"id" => "a"}, 100, 100)
    assert Cursor.get("t") == %{"id" => "a"}
    :ok = Cursor.advance("t", %{"id" => "b"}, 100, 100)
    assert Cursor.get("t") == %{"id" => "b"}
    :ok = Cursor.advance("t", %{"id" => "c"}, 3, 100)
    assert Cursor.get("t") == nil
    :ok = Cursor.advance("t", false, 0, 100)
    assert Cursor.get("t") == nil
  end

  # `_` and `%` are LIKE wildcards; a family match is literal.
  test "family/1 matches the base and base:<suffix> only, literally" do
    for name <- ~w(a_b a_b:1 a_b:x_y aXb aXb:1 a_bc a_b_c a%b:1),
        do: :ok = Cursor.put(name, %{"n" => name})

    assert Cursor.family("a_b") |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
             ~w(a_b a_b:1 a_b:x_y)

    assert Cursor.family("a%b") |> Enum.map(&elem(&1, 0)) == ["a%b:1"]
  end
end
