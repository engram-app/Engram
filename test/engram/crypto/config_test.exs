defmodule Engram.Crypto.ConfigTest do
  use ExUnit.Case, async: false
  alias Engram.Crypto.Config

  @valid_key_b64 Base.encode64(:crypto.strong_rand_bytes(32))

  setup do
    orig = Application.get_all_env(:engram)

    on_exit(fn ->
      Application.put_env(:engram, :key_provider, Keyword.get(orig, :key_provider))

      Application.put_env(
        :engram,
        :encryption_master_key,
        Keyword.get(orig, :encryption_master_key)
      )
    end)

    :ok
  end

  test "valid local config passes" do
    Application.put_env(:engram, :key_provider, Engram.Crypto.KeyProvider.Local)
    Application.put_env(:engram, :encryption_master_key, @valid_key_b64)
    assert :ok = Config.validate!()
  end

  test "crashes on missing master key when provider is local" do
    Application.put_env(:engram, :key_provider, Engram.Crypto.KeyProvider.Local)
    Application.put_env(:engram, :encryption_master_key, nil)
    assert_raise RuntimeError, ~r/ENCRYPTION_MASTER_KEY/, fn -> Config.validate!() end
  end

  test "crashes on malformed master key" do
    Application.put_env(:engram, :key_provider, Engram.Crypto.KeyProvider.Local)
    Application.put_env(:engram, :encryption_master_key, "not-base64!!!")
    assert_raise RuntimeError, ~r/base64/, fn -> Config.validate!() end
  end

  test "crashes on wrong-length master key" do
    short = Base.encode64(:crypto.strong_rand_bytes(16))
    Application.put_env(:engram, :key_provider, Engram.Crypto.KeyProvider.Local)
    Application.put_env(:engram, :encryption_master_key, short)
    assert_raise RuntimeError, ~r/32 bytes/, fn -> Config.validate!() end
  end

  test "crashes on unknown provider" do
    Application.put_env(:engram, :key_provider, NotAModule)
    assert_raise RuntimeError, ~r/unknown/i, fn -> Config.validate!() end
  end

  test "crashes with clear message when key_provider is not configured" do
    Application.put_env(:engram, :key_provider, nil)
    assert_raise RuntimeError, ~r/not configured/, fn -> Config.validate!() end
  end
end
