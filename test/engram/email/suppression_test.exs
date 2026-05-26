defmodule Engram.Email.SuppressionTest do
  use Engram.DataCase, async: true

  alias Engram.Email.Suppression

  test "suppress/2 records an address that suppressed?/1 then reports" do
    assert {:ok, _} = Suppression.suppress("bounce@example.com", "bounced")
    assert Suppression.suppressed?("bounce@example.com")
    refute Suppression.suppressed?("clean@example.com")
  end

  test "matching is case-insensitive" do
    assert {:ok, _} = Suppression.suppress("Mixed@Example.com", "complained")
    assert Suppression.suppressed?("mixed@example.com")
  end

  test "suppressing the same address twice is idempotent" do
    assert {:ok, _} = Suppression.suppress("dup@example.com", "bounced")
    assert {:ok, _} = Suppression.suppress("dup@example.com", "complained")
    assert Suppression.suppressed?("dup@example.com")
  end

  test "rejects an invalid reason" do
    assert {:error, _} = Suppression.suppress("x@example.com", "nonsense")
    refute Suppression.suppressed?("x@example.com")
  end
end
