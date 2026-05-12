defmodule Engram.Crypto.KeyProvider.AwsKmsTest do
  use ExUnit.Case, async: false

  import Mox

  alias Engram.Crypto.KeyProvider.AwsKms

  setup :verify_on_exit!

  setup do
    prev = Application.get_env(:engram, :aws_kms_client)
    Application.put_env(:engram, :aws_kms_client, Engram.AwsKmsMock)
    on_exit(fn -> Application.put_env(:engram, :aws_kms_client, prev) end)
    :ok
  end

  test "name/0 returns :aws_kms" do
    assert AwsKms.name() == :aws_kms
  end

  test "generate_dek/0 returns 32 bytes" do
    assert byte_size(AwsKms.generate_dek()) == 32
  end

  test "supports_async_workers?/0 returns true" do
    assert AwsKms.supports_async_workers?() == true
  end

  test "wrap_dek emits 0xAA-prefixed blob with KMS ciphertext" do
    dek = <<1::256>>

    expect(Engram.AwsKmsMock, :encrypt, fn ^dek, ctx ->
      assert ctx == %{"user_id" => "7", "purpose" => "dek_wrap"}
      {:ok, <<0xDE, 0xAD, 0xBE, 0xEF>>}
    end)

    {:ok, wrapped} = AwsKms.wrap_dek(dek, %{user_id: 7})
    assert <<0xAA, 0x01, 0xDE, 0xAD, 0xBE, 0xEF>> == wrapped
  end

  test "unwrap_dek strips the header and returns the 32-byte DEK" do
    expect(Engram.AwsKmsMock, :decrypt, fn <<0xDE, 0xAD>>, ctx ->
      assert ctx == %{"user_id" => "7", "purpose" => "dek_wrap"}
      {:ok, <<2::256>>}
    end)

    assert {:ok, <<2::256>>} =
             AwsKms.unwrap_dek(<<0xAA, 0x01, 0xDE, 0xAD>>, %{user_id: 7})
  end

  test "unwrap_dek rejects non-tagged blobs" do
    assert {:error, :malformed_wrapped_blob} =
             AwsKms.unwrap_dek(<<0x02, 0x01, 0x00>>, %{user_id: 7})
  end

  test "unwrap_dek rejects unknown payload versions" do
    assert {:error, :malformed_wrapped_blob} =
             AwsKms.unwrap_dek(<<0xAA, 0x02, 0xDE, 0xAD>>, %{user_id: 7})
  end

  test "unwrap_dek surfaces :access_denied unchanged" do
    expect(Engram.AwsKmsMock, :decrypt, fn _, _ -> {:error, :access_denied} end)

    assert {:error, :kms_access_denied} =
             AwsKms.unwrap_dek(<<0xAA, 0x01, 0xDE, 0xAD>>, %{user_id: 7})
  end

  test "unwrap_dek maps :context_mismatch to :invalid_wrapping" do
    expect(Engram.AwsKmsMock, :decrypt, fn _, _ -> {:error, :context_mismatch} end)

    assert {:error, :invalid_wrapping} =
             AwsKms.unwrap_dek(<<0xAA, 0x01, 0xDE, 0xAD>>, %{user_id: 7})
  end

  test "unwrap_dek surfaces :throttled" do
    expect(Engram.AwsKmsMock, :decrypt, fn _, _ -> {:error, :throttled} end)

    assert {:error, :kms_throttled} =
             AwsKms.unwrap_dek(<<0xAA, 0x01, 0xDE, 0xAD>>, %{user_id: 7})
  end

  test "rotate_wrapping re-encrypts under the same context" do
    expect(Engram.AwsKmsMock, :re_encrypt, fn <<0xDE, 0xAD>>, src, dst ->
      assert src == %{"user_id" => "7", "purpose" => "dek_wrap"}
      assert dst == src
      {:ok, <<0xBB, 0xCC>>}
    end)

    {:ok, rotated} =
      AwsKms.rotate_wrapping(<<0xAA, 0x01, 0xDE, 0xAD>>, %{user_id: 7})

    assert rotated == <<0xAA, 0x01, 0xBB, 0xCC>>
  end

  test "rotate_dek returns fresh 32-byte DEK plus new wrapped blob" do
    expect(Engram.AwsKmsMock, :encrypt, fn dek, _ctx ->
      assert byte_size(dek) == 32
      {:ok, <<0x11, 0x22>>}
    end)

    {:ok, wrapped, new_dek} = AwsKms.rotate_dek(<<0xAA, 0x01, 0xDE, 0xAD>>, %{user_id: 7})
    assert byte_size(new_dek) == 32
    assert wrapped == <<0xAA, 0x01, 0x11, 0x22>>
  end

  test "wrap_dek surfaces upstream encrypt failure" do
    expect(Engram.AwsKmsMock, :encrypt, fn _, _ -> {:error, :throttled} end)

    assert {:error, {:kms_encrypt_failed, :throttled}} =
             AwsKms.wrap_dek(<<1::256>>, %{user_id: 7})
  end

  test "wrap_dek requires user_id in ctx" do
    assert_raise FunctionClauseError, fn ->
      AwsKms.wrap_dek(<<1::256>>, %{})
    end
  end

  test "rotate_wrapping rejects non-tagged blobs" do
    assert {:error, :malformed_wrapped_blob} =
             AwsKms.rotate_wrapping(<<0x02, 0x01, 0x00>>, %{user_id: 7})
  end

  test "rotate_wrapping rejects unknown payload versions" do
    assert {:error, :malformed_wrapped_blob} =
             AwsKms.rotate_wrapping(<<0xAA, 0x02, 0xDE, 0xAD>>, %{user_id: 7})
  end

  test "rotate_dek requires user_id in ctx" do
    assert_raise FunctionClauseError, fn ->
      AwsKms.rotate_dek(<<0xAA, 0x01, 0xDE, 0xAD>>, %{})
    end
  end
end
