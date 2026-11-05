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

  test "stores reason as an atom and accepts an atom reason" do
    assert {:ok, s} = Suppression.suppress("atom@example.com", :bounced)
    assert s.reason == :bounced
  end

  # email_suppressions.email is varchar(255), fed from the Resend webhook. An
  # over-long address raised on INSERT instead of returning a changeset error.
  test "refuses an address over 255 codepoints and accepts 255" do
    long = String.duplicate("a", 244) <> "@example.com"
    assert String.length(long) == 256
    assert {:error, %Ecto.Changeset{errors: errors}} = Suppression.suppress(long, :bounced)
    assert Keyword.has_key?(errors, :email)

    ok = String.duplicate("a", 243) <> "@example.com"
    assert {:ok, _} = Suppression.suppress(ok, :bounced)
  end
end
