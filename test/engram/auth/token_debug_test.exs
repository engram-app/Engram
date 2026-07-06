defmodule Engram.Auth.TokenDebugTest.Fixtures do
  @moduledoc false

  # Bare-secret HS256 signer, same idiom as test/engram/token_test.exs. This
  # is a throwaway signer used only to produce a well-formed JWT string for
  # TokenDebug to peek at; TokenDebug never verifies, so the secret never
  # matters to the assertions below.
  def hs256(claims) do
    signer = Joken.Signer.create("HS256", "throwaway-test-secret")
    {:ok, token} = Joken.Signer.sign(claims, signer)
    token
  end
end

defmodule Engram.Auth.TokenDebugTest do
  use ExUnit.Case, async: true

  test "peeks header + claims of an unverified HS256 JWT" do
    # token below is signed with a throwaway secret; TokenDebug must NOT verify it.
    token = Engram.Auth.TokenDebugTest.Fixtures.hs256(%{"iss" => "engram", "sub" => "user_123"})
    md = Engram.Auth.TokenDebug.metadata(token)
    assert md[:alg] == "HS256"
    assert md[:iss] == "engram"
    assert md[:sub_hash] == Engram.Crypto.HMAC.hash_user_id("user_123")
    refute md[:sub_hash] == "user_123"
  end

  test "returns all-nil metadata for a non-JWT string without raising" do
    assert Engram.Auth.TokenDebug.metadata("not-a-jwt") == [
             alg: nil,
             kid: nil,
             iss: nil,
             sub_hash: nil
           ]
  end
end
