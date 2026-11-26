defmodule Engram.KeywordStore.Tantivy.TokenTest do
  use ExUnit.Case, async: true

  alias Engram.KeywordStore.Tantivy.Token

  @current "current-key-0123456789abcdef0123456789"
  @next "next-key-0123456789abcdef0123456789abcd"
  @now 1_800_000_000

  test "a search token carries exactly the user, the vaults and an expiry" do
    token = Token.search("u-a", ["v-1", "v-2"], @current, @now)

    assert {:ok, %{"s" => "search", "u" => "u-a", "v" => ["v-1", "v-2"], "exp" => exp}} =
             Token.verify(token, [@current], @now)

    assert exp == @now + 60
  end

  test "rotation: a token signed with either key passes during the overlap" do
    by_current = Token.ops(@current, @now)
    by_next = Token.ops(@next, @now)

    assert {:ok, _} = Token.verify(by_current, [@current, @next], @now)
    assert {:ok, _} = Token.verify(by_next, [@current, @next], @now)
  end

  test "rotation: the retired key fails once it is off the list" do
    assert :error = Token.verify(Token.ops(@current, @now), [@next], @now)
  end

  test "a tampered payload fails: the tenant cannot be swapped under the signature" do
    [_body, sig] = @current |> then(&Token.search("u-a", ["v-1"], &1, @now)) |> String.split(".")

    forged =
      %{"s" => "search", "u" => "u-b", "v" => ["v-1"], "exp" => @now + 60}
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    assert :error = Token.verify(forged <> "." <> sig, [@current], @now)
  end

  test "expired, too far ahead and malformed tokens fail" do
    assert :error = Token.verify(Token.ops(@current, @now - 61), [@current], @now)
    assert :error = Token.verify(Token.sign(%{"exp" => @now + 301}, @current), [@current], @now)
    assert :error = Token.verify("not-a-token", [@current], @now)
    assert :error = Token.verify("a.b.c", [@current], @now)
  end
end
