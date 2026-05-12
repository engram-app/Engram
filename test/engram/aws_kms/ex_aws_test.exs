defmodule Engram.AwsKms.ExAwsTest do
  use ExUnit.Case, async: false

  alias Engram.AwsKms.ExAws, as: KmsExAws

  setup do
    bypass = Bypass.open()

    prev_ex_aws_kms =
      Application.get_env(:ex_aws, :kms)

    prev_ex_aws =
      [
        access_key_id: Application.get_env(:ex_aws, :access_key_id),
        secret_access_key: Application.get_env(:ex_aws, :secret_access_key),
        region: Application.get_env(:ex_aws, :region)
      ]

    Application.put_env(:ex_aws, :access_key_id, "AKIA_TEST")
    Application.put_env(:ex_aws, :secret_access_key, "secret_test")
    Application.put_env(:ex_aws, :region, "us-east-1")

    Application.put_env(
      :ex_aws,
      :kms,
      scheme: "http://",
      host: "localhost",
      port: bypass.port
    )

    Application.put_env(
      :engram,
      :aws_kms_key_id,
      "arn:aws:kms:us-east-1:000000000000:key/fixture-key-id"
    )

    on_exit(fn ->
      Application.put_env(:ex_aws, :kms, prev_ex_aws_kms)

      for {k, v} <- prev_ex_aws do
        if is_nil(v), do: Application.delete_env(:ex_aws, k), else: Application.put_env(:ex_aws, k, v)
      end
    end)

    {:ok, bypass: bypass}
  end

  test "encrypt/2 sends EncryptionContext + KeyId and returns ciphertext", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)

      assert decoded["KeyId"] ==
               "arn:aws:kms:us-east-1:000000000000:key/fixture-key-id"

      assert decoded["EncryptionContext"] == %{
               "user_id" => "42",
               "purpose" => "dek_wrap"
             }

      assert Base.decode64!(decoded["Plaintext"]) == <<1::256>>

      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!(%{
          "CiphertextBlob" => Base.encode64(<<0xDE, 0xAD, 0xBE, 0xEF>>),
          "KeyId" => decoded["KeyId"]
        })
      )
    end)

    assert {:ok, <<0xDE, 0xAD, 0xBE, 0xEF>>} =
             KmsExAws.encrypt(<<1::256>>, %{"user_id" => "42", "purpose" => "dek_wrap"})
  end

  test "decrypt/2 returns plaintext on 200", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)

      assert decoded["EncryptionContext"] == %{"user_id" => "9", "purpose" => "dek_wrap"}
      assert Base.decode64!(decoded["CiphertextBlob"]) == <<0xCA, 0xFE>>

      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!(%{"Plaintext" => Base.encode64(<<2::256>>)})
      )
    end)

    assert {:ok, <<2::256>>} =
             KmsExAws.decrypt(<<0xCA, 0xFE>>, %{"user_id" => "9", "purpose" => "dek_wrap"})
  end

  test "decrypt/2 maps AccessDeniedException to :access_denied", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/", fn conn ->
      Plug.Conn.resp(
        conn,
        400,
        Jason.encode!(%{
          "__type" => "AccessDeniedException",
          "message" => "User not authorized to perform kms:Decrypt"
        })
      )
    end)

    assert {:error, :access_denied} =
             KmsExAws.decrypt(<<0xCA, 0xFE>>, %{"user_id" => "9", "purpose" => "dek_wrap"})
  end

  test "decrypt/2 maps ThrottlingException to :throttled", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/", fn conn ->
      Plug.Conn.resp(
        conn,
        400,
        Jason.encode!(%{"__type" => "ThrottlingException", "message" => "Rate exceeded"})
      )
    end)

    assert {:error, :throttled} =
             KmsExAws.decrypt(<<0xCA, 0xFE>>, %{"user_id" => "9", "purpose" => "dek_wrap"})
  end

  test "decrypt/2 maps InvalidCiphertextException to :context_mismatch", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/", fn conn ->
      Plug.Conn.resp(
        conn,
        400,
        Jason.encode!(%{"__type" => "InvalidCiphertextException", "message" => ""})
      )
    end)

    assert {:error, :context_mismatch} =
             KmsExAws.decrypt(<<0xCA, 0xFE>>, %{"user_id" => "9", "purpose" => "dek_wrap"})
  end

  test "decrypt/2 maps NotFoundException to :key_not_found", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/", fn conn ->
      Plug.Conn.resp(
        conn,
        400,
        Jason.encode!(%{"__type" => "NotFoundException", "message" => "Key not found"})
      )
    end)

    assert {:error, :key_not_found} =
             KmsExAws.decrypt(<<0xCA, 0xFE>>, %{"user_id" => "9", "purpose" => "dek_wrap"})
  end

  test "describe_key/0 returns :ok on 200", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/", fn conn ->
      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!(%{
          "KeyMetadata" => %{
            "KeyId" => "fixture-key-id",
            "Enabled" => true
          }
        })
      )
    end)

    assert :ok = KmsExAws.describe_key()
  end

  test "re_encrypt/3 returns rewrapped ciphertext", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)

      assert decoded["SourceEncryptionContext"] == %{
               "user_id" => "5",
               "purpose" => "dek_wrap"
             }

      assert decoded["DestinationEncryptionContext"] == %{
               "user_id" => "5",
               "purpose" => "dek_wrap"
             }

      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!(%{
          "CiphertextBlob" => Base.encode64(<<0xBB, 0xCC>>),
          "KeyId" => decoded["DestinationKeyId"],
          "SourceKeyId" => decoded["DestinationKeyId"]
        })
      )
    end)

    ctx = %{"user_id" => "5", "purpose" => "dek_wrap"}
    assert {:ok, <<0xBB, 0xCC>>} = KmsExAws.re_encrypt(<<0xAA>>, ctx, ctx)
  end
end
