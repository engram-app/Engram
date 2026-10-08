defmodule Engram.Crypto.EnvelopeGoldenTest do
  use ExUnit.Case, async: true
  alias Engram.Crypto.Envelope

  @golden "test/support/fixtures/envelope_golden.json" |> File.read!() |> Jason.decode!()

  test "every ciphertext written by the :crypto envelope still opens" do
    for c <- @golden do
      [key, aad, plain, nonce, ct] =
        Enum.map(~w(key aad plaintext nonce ct), &Base.decode64!(c[&1]))

      assert Envelope.decrypt(ct, nonce, key, aad) == {:ok, plain}, inspect(c["aad"])
    end
  end
end
