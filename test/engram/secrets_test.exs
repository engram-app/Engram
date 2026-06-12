defmodule Engram.SecretsTest do
  use ExUnit.Case, async: true
  alias Engram.Secrets

  test "nil blob returns empty map" do
    assert Secrets.unpack(nil, fn _ -> nil end) == %{}
  end

  test "expands all keys when env is empty" do
    blob = ~s({"A":"1","B":"2"})
    assert Secrets.unpack(blob, fn _ -> nil end) == %{"A" => "1", "B" => "2"}
  end

  test "an individually-set env var wins and is excluded" do
    blob = ~s({"A":"1","B":"2"})
    getenv = fn
      "A" -> "override"
      _ -> nil
    end

    assert Secrets.unpack(blob, getenv) == %{"B" => "2"}
  end

  test "coerces non-string JSON values to strings" do
    blob = ~s({"N":42,"B":true})
    assert Secrets.unpack(blob, fn _ -> nil end) == %{"N" => "42", "B" => "true"}
  end

  test "malformed JSON raises" do
    assert_raise Jason.DecodeError, fn -> Secrets.unpack("{not json", fn _ -> nil end) end
  end

  test "non-object JSON raises ArgumentError" do
    assert_raise ArgumentError, fn -> Secrets.unpack("[1,2,3]", fn _ -> nil end) end
  end
end
