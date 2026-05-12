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

  describe "validate!/0 aws_kms branch" do
    setup do
      prev_provider = Application.get_env(:engram, :key_provider)
      prev_key_id = Application.get_env(:engram, :aws_kms_key_id)
      prev_region = Application.get_env(:engram, :aws_kms_region)
      prev_access = Application.get_env(:ex_aws, :access_key_id)
      prev_secret = Application.get_env(:ex_aws, :secret_access_key)

      on_exit(fn ->
        Application.put_env(:engram, :key_provider, prev_provider)

        if is_nil(prev_key_id),
          do: Application.delete_env(:engram, :aws_kms_key_id),
          else: Application.put_env(:engram, :aws_kms_key_id, prev_key_id)

        if is_nil(prev_region),
          do: Application.delete_env(:engram, :aws_kms_region),
          else: Application.put_env(:engram, :aws_kms_region, prev_region)

        if is_nil(prev_access),
          do: Application.delete_env(:ex_aws, :access_key_id),
          else: Application.put_env(:ex_aws, :access_key_id, prev_access)

        if is_nil(prev_secret),
          do: Application.delete_env(:ex_aws, :secret_access_key),
          else: Application.put_env(:ex_aws, :secret_access_key, prev_secret)
      end)

      Application.put_env(:engram, :key_provider, Engram.Crypto.KeyProvider.AwsKms)
      :ok
    end

    test "passes when all env vars are present" do
      Application.put_env(
        :engram,
        :aws_kms_key_id,
        "arn:aws:kms:us-east-1:000000000000:key/abc"
      )

      Application.put_env(:engram, :aws_kms_region, "us-east-1")
      Application.put_env(:ex_aws, :access_key_id, "AKIA_TEST")
      Application.put_env(:ex_aws, :secret_access_key, "secret_test")

      assert :ok = Config.validate!()
    end

    test "raises when AWS_KMS_KEY_ID is missing" do
      Application.delete_env(:engram, :aws_kms_key_id)
      Application.put_env(:engram, :aws_kms_region, "us-east-1")
      Application.put_env(:ex_aws, :access_key_id, "AKIA_TEST")
      Application.put_env(:ex_aws, :secret_access_key, "secret_test")

      assert_raise RuntimeError, ~r/AWS_KMS_KEY_ID/, fn ->
        Config.validate!()
      end
    end

    test "raises when AWS_KMS_KEY_ID has wrong shape" do
      Application.put_env(:engram, :aws_kms_key_id, "not-an-arn")
      Application.put_env(:engram, :aws_kms_region, "us-east-1")
      Application.put_env(:ex_aws, :access_key_id, "AKIA_TEST")
      Application.put_env(:ex_aws, :secret_access_key, "secret_test")

      assert_raise RuntimeError, ~r/AWS_KMS_KEY_ID/, fn ->
        Config.validate!()
      end
    end

    test "raises when AWS_REGION is missing" do
      Application.put_env(:engram, :aws_kms_key_id, "alias/engram")
      Application.delete_env(:engram, :aws_kms_region)
      Application.put_env(:ex_aws, :access_key_id, "AKIA_TEST")
      Application.put_env(:ex_aws, :secret_access_key, "secret_test")

      assert_raise RuntimeError, ~r/AWS_REGION/, fn ->
        Config.validate!()
      end
    end

    test "raises when AWS_ACCESS_KEY_ID is missing" do
      Application.put_env(:engram, :aws_kms_key_id, "alias/engram")
      Application.put_env(:engram, :aws_kms_region, "us-east-1")
      Application.delete_env(:ex_aws, :access_key_id)
      Application.put_env(:ex_aws, :secret_access_key, "secret_test")

      assert_raise RuntimeError, ~r/AWS_ACCESS_KEY_ID/, fn ->
        Config.validate!()
      end
    end

    test "raises when AWS_SECRET_ACCESS_KEY is missing" do
      Application.put_env(:engram, :aws_kms_key_id, "alias/engram")
      Application.put_env(:engram, :aws_kms_region, "us-east-1")
      Application.put_env(:ex_aws, :access_key_id, "AKIA_TEST")
      Application.delete_env(:ex_aws, :secret_access_key)

      assert_raise RuntimeError, ~r/AWS_SECRET_ACCESS_KEY/, fn ->
        Config.validate!()
      end
    end

    test "accepts alias/... key id form" do
      Application.put_env(:engram, :aws_kms_key_id, "alias/engram-dek-wrap")
      Application.put_env(:engram, :aws_kms_region, "us-east-1")
      Application.put_env(:ex_aws, :access_key_id, "AKIA_TEST")
      Application.put_env(:ex_aws, :secret_access_key, "secret_test")

      assert :ok = Config.validate!()
    end
  end
end
