defmodule Engram.Instance.SetupTokenTest do
  # async: false — mutates :auth_provider and :setup_token app env.
  use Engram.DataCase, async: false

  import ExUnit.CaptureLog

  alias Engram.Instance.SetupToken

  require Logger

  setup do
    prev_provider = Application.get_env(:engram, :auth_provider)
    prev_token = Application.get_env(:engram, :setup_token)
    Application.put_env(:engram, :auth_provider, :local)
    Application.delete_env(:engram, :setup_token)

    on_exit(fn ->
      Application.put_env(:engram, :auth_provider, prev_provider || :local)
      Application.put_env(:engram, :setup_token, prev_token)
    end)

    :ok
  end

  # config/test.exs runs the logger at :warning; the boot line is :info. This
  # file is async: false, so raising the global level here is safe.
  defp boot_log do
    previous = Logger.level()
    Logger.configure(level: :info)

    try do
      capture_log([level: :info], fn -> assert SetupToken.boot() == :ok end)
    after
      Logger.configure(level: previous)
    end
  end

  # Pull the printed token back out of the one boot line that carries it.
  defp printed_token(log) do
    [_, token] = Regex.run(~r/create it: (\S+) /, log)
    token
  end

  describe "boot/0" do
    test "mints a token while bootstrap is pending and prints it once" do
      log = boot_log()

      token = printed_token(log)
      assert byte_size(token) >= 32
      assert SetupToken.valid?(token)
      # Printed on exactly one line.
      assert length(String.split(log, token)) == 2
    end

    test "stores only a hash, never the raw token" do
      token = printed_token(boot_log())

      %{token_hash: stored} = Engram.Repo.one!(SetupToken.Row, skip_tenant_check: true)

      refute stored == token
      refute String.contains?(stored, token)
    end

    test "rotates on every boot: the previous token stops working" do
      first = printed_token(boot_log())
      second = printed_token(boot_log())

      refute first == second
      refute SetupToken.valid?(first)
      assert SetupToken.valid?(second)
    end

    test "uses ENGRAM_SETUP_TOKEN when set and never logs its value" do
      Application.put_env(:engram, :setup_token, "fixed-ci-token-abcdefgh")

      log = boot_log()

      assert SetupToken.valid?("fixed-ci-token-abcdefgh")
      assert log =~ "ENGRAM_SETUP_TOKEN"
      refute log =~ "fixed-ci-token-abcdefgh"
    end

    test "mints nothing and clears any leftover once the admin exists" do
      {:ok, _} = SetupToken.mint("leftover-token-abcdefgh")
      {:ok, _} = Engram.Instance.mark_bootstrap_complete()

      log = boot_log()

      refute SetupToken.valid?("leftover-token-abcdefgh")
      refute log =~ "first-run setup"
    end

    test "does nothing under Clerk (SaaS has no claim window)" do
      Application.put_env(:engram, :auth_provider, :clerk)

      log = boot_log()

      refute log =~ "first-run setup"
      assert Engram.Repo.all(SetupToken.Row, skip_tenant_check: true) == []
    end
  end

  describe "valid?/1" do
    test "rejects everything when no token exists" do
      refute SetupToken.valid?("anything")
      refute SetupToken.valid?("")
      refute SetupToken.valid?(nil)
      refute SetupToken.valid?(%{"a" => 1})
    end

    test "rejects a blank candidate even when a token exists" do
      {:ok, _} = SetupToken.mint("real-token-abcdefgh")

      refute SetupToken.valid?("")
      refute SetupToken.valid?("   ")
      assert SetupToken.valid?("real-token-abcdefgh")
    end
  end

  test "the admin claim transaction burns the token" do
    {:ok, _} = SetupToken.mint("claim-token-abcdefgh")

    {:ok, user} = Engram.Accounts.create_user_with_password("boss@x.com", "longpassword1")

    assert user.role == "admin"
    refute SetupToken.valid?("claim-token-abcdefgh")
  end
end
