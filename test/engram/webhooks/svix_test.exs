defmodule Engram.Webhooks.SvixTest do
  use ExUnit.Case, async: true

  alias Engram.Webhooks.Svix

  @secret_raw "supersecretkey-supersecretkey32!"
  @secret "whsec_" <> Base.encode64(@secret_raw)

  defp sign(id, ts, payload) do
    "v1," <>
      (:crypto.mac(:hmac, :sha256, @secret_raw, "#{id}.#{ts}.#{payload}") |> Base.encode64())
  end

  describe "verify/5" do
    test "accepts a correctly signed, fresh payload" do
      ts = to_string(System.system_time(:second))
      payload = ~s({"type":"email.bounced"})
      sig = sign("msg_1", ts, payload)

      assert :ok = Svix.verify("msg_1", ts, payload, sig, @secret)
    end

    test "accepts when one of several space-separated signatures matches" do
      ts = to_string(System.system_time(:second))
      payload = ~s({"a":1})
      sig = "v1,bogus " <> sign("msg_1", ts, payload)

      assert :ok = Svix.verify("msg_1", ts, payload, sig, @secret)
    end

    test "rejects a tampered payload" do
      ts = to_string(System.system_time(:second))
      sig = sign("msg_1", ts, ~s({"a":1}))

      assert {:error, _} = Svix.verify("msg_1", ts, ~s({"a":2}), sig, @secret)
    end

    test "rejects a stale timestamp (replay)" do
      ts = to_string(System.system_time(:second) - 1000)
      payload = ~s({"a":1})
      sig = sign("msg_1", ts, payload)

      assert {:error, _} = Svix.verify("msg_1", ts, payload, sig, @secret)
    end

    test "rejects a missing secret" do
      ts = to_string(System.system_time(:second))
      assert {:error, _} = Svix.verify("msg_1", ts, "{}", "v1,x", nil)
      assert {:error, _} = Svix.verify("msg_1", ts, "{}", "v1,x", "")
    end
  end
end
