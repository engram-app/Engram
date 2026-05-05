defmodule Engram.TokenTest do
  use ExUnit.Case, async: true

  alias Engram.Token

  # Signer helper: Application.get_env(:joken, :default_signer) returns a bare string
  # (e.g. "test-jwt-secret"). Joken.Signer.create/2 accepts a bare string for HMAC
  # algorithms — no %{"secret" => key} wrapper needed.
  defp test_signer do
    Joken.Signer.create("HS256", Application.get_env(:joken, :default_signer))
  end

  test "generated tokens include iss and aud claims" do
    {:ok, _token, claims} = Token.generate_and_sign(%{"user_id" => 1})
    assert claims["iss"] == "engram"
    assert claims["aud"] == "engram"
  end

  # Positive control: a well-formed token with correct iss+aud must be accepted.
  # If this fails, the signer is constructed incorrectly and all rejection tests
  # would be meaningless (they'd error on signature, not claim validation).
  test "well-formed token with correct iss and aud is accepted" do
    claims = %{
      "user_id" => 1,
      "iss" => "engram",
      "aud" => "engram",
      "exp" => Joken.current_time() + 3600
    }

    {:ok, token} = Joken.Signer.sign(claims, test_signer())
    assert {:ok, _} = Token.verify_and_validate(token)
  end

  test "tokens with wrong issuer are rejected" do
    claims = %{
      "user_id" => 1,
      "iss" => "other_app",
      "aud" => "engram",
      "exp" => Joken.current_time() + 3600
    }

    {:ok, token} = Joken.Signer.sign(claims, test_signer())

    assert {:error, [message: "Invalid token", claim: "iss", claim_val: "other_app"]} =
             Token.verify_and_validate(token)
  end

  test "tokens with wrong audience are rejected" do
    claims = %{
      "user_id" => 1,
      "iss" => "engram",
      "aud" => "other_app",
      "exp" => Joken.current_time() + 3600
    }

    {:ok, token} = Joken.Signer.sign(claims, test_signer())

    assert {:error, [message: "Invalid token", claim: "aud", claim_val: "other_app"]} =
             Token.verify_and_validate(token)
  end

  test "tokens missing iss claim are rejected" do
    claims = %{"user_id" => 1, "aud" => "engram", "exp" => Joken.current_time() + 3600}
    {:ok, token} = Joken.Signer.sign(claims, test_signer())

    assert {:error, [message: "Invalid token", missing_claims: ["iss"]]} =
             Token.verify_and_validate(token)
  end

  test "tokens missing aud claim are rejected" do
    claims = %{"user_id" => 1, "iss" => "engram", "exp" => Joken.current_time() + 3600}
    {:ok, token} = Joken.Signer.sign(claims, test_signer())

    assert {:error, [message: "Invalid token", missing_claims: ["aud"]]} =
             Token.verify_and_validate(token)
  end
end
