defmodule Engram.AuthTest do
  # async: false — tests mutate global Application config
  use ExUnit.Case, async: false

  setup do
    prev = Application.get_env(:engram, :auth_provider)
    on_exit(fn -> Application.put_env(:engram, :auth_provider, prev || :local) end)
    %{prev: prev}
  end

  describe "rejection_label/1" do
    test "stringifies a bare atom reason" do
      assert Engram.Auth.rejection_label(:no_auth) == "no_auth"
      assert Engram.Auth.rejection_label(:missing_claims) == "missing_claims"
    end

    test "names the offending claim from a Joken keyword-list reason" do
      assert Engram.Auth.rejection_label(message: "Invalid token", claim: "exp") ==
               "claim_invalid:exp"
    end

    test "collapses a claimless Joken reason to a low-cardinality label (no free-text)" do
      # The metric tag must stay bounded — the variable Joken message never
      # becomes a tag value.
      assert Engram.Auth.rejection_label(message: "some variable detail") == "invalid_token"
    end

    test "falls back to a bounded label for anything else" do
      assert Engram.Auth.rejection_label(%{weird: "shape"}) == "other"
    end
  end

  describe "emit_rejected/2" do
    test "emits [:engram, :auth, :rejected] tagged by reason + source, returns the label" do
      test_pid = self()
      handler = {__MODULE__, :auth_rejected, test_pid}

      :telemetry.attach(
        handler,
        [:engram, :auth, :rejected],
        fn _e, m, meta, _ -> send(test_pid, {:auth_rejected, m, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert "claim_invalid:exp" =
               Engram.Auth.emit_rejected([message: "x", claim: "exp"], :socket)

      assert_received {:auth_rejected, %{count: 1}, %{reason: "claim_invalid:exp", source: :socket}}
    end
  end

  describe "provider/0" do
    test "returns Local provider by default" do
      Application.put_env(:engram, :auth_provider, :local)
      assert Engram.Auth.provider() == Engram.Auth.Providers.Local
    end

    test "returns Clerk provider when configured" do
      Application.put_env(:engram, :auth_provider, :clerk)
      assert Engram.Auth.provider() == Engram.Auth.Providers.Clerk
    end

    test "raises on invalid provider config" do
      Application.put_env(:engram, :auth_provider, :invalid)

      assert_raise RuntimeError, ~r/Invalid :auth_provider config/, fn ->
        Engram.Auth.provider()
      end
    end
  end

  describe "supports_credentials?/0" do
    test "returns true for local provider" do
      Application.put_env(:engram, :auth_provider, :local)
      assert Engram.Auth.supports_credentials?() == true
    end

    test "returns false for clerk provider" do
      Application.put_env(:engram, :auth_provider, :clerk)
      assert Engram.Auth.supports_credentials?() == false
    end
  end
end
