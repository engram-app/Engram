defmodule Engram.Auth.SignupRejectionsTest do
  use ExUnit.Case, async: true

  alias Engram.Auth.SignupRejections

  defp uniq, do: "user_" <> Integer.to_string(System.unique_integer([:positive]))

  describe "record/3 and fetch/1" do
    test "fetch returns the recorded reason" do
      id = uniq()
      :ok = SignupRejections.record(id, :duplicate_identity)
      assert {:ok, :duplicate_identity} = SignupRejections.fetch(id)
    end

    test "fetch returns :error for an unknown id" do
      assert :error = SignupRejections.fetch(uniq())
    end

    test "an expired record is not returned" do
      id = uniq()
      # negative ttl => already expired the instant it is written
      :ok = SignupRejections.record(id, :duplicate_identity, -1)
      assert :error = SignupRejections.fetch(id)
    end

    test "records are isolated by id" do
      a = uniq()
      b = uniq()
      :ok = SignupRejections.record(a, :duplicate_identity)
      assert :error = SignupRejections.fetch(b)
      assert {:ok, :duplicate_identity} = SignupRejections.fetch(a)
    end
  end
end
