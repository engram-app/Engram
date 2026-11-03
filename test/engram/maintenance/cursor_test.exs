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
end
