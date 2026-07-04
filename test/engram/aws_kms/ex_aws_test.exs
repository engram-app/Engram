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
        if is_nil(v),
          do: Application.delete_env(:ex_aws, k),
          else: Application.put_env(:ex_aws, k, v)
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

      assert decoded["DestinationKeyId"] ==
               "arn:aws:kms:us-east-1:000000000000:key/fixture-key-id"

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

  describe "telemetry" do
    test "emits :request event with duration_us, op, status on successful encrypt", %{
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "POST", "/", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"CiphertextBlob":"#{Base.encode64("ct")}"}))
      end)

      :telemetry.attach(
        "kms-req-ok",
        [:engram, :crypto, :kms, :request],
        fn _name, meas, meta, _ -> send(self(), {:tel_req, meas, meta}) end,
        nil
      )

      try do
        assert {:ok, "ct"} =
                 KmsExAws.encrypt("pt", %{"user_id" => "1", "purpose" => "dek_wrap"})

        assert_received {:tel_req, %{duration_us: dur}, %{op: :encrypt, status: :ok}}
        assert is_integer(dur) and dur >= 0
      after
        :telemetry.detach("kms-req-ok")
      end
    end

    test "emits :failure event with error_class on AccessDenied", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/", fn conn ->
        Plug.Conn.resp(
          conn,
          400,
          ~s({"__type":"AccessDeniedException","message":"nope"})
        )
      end)

      :telemetry.attach_many(
        "kms-failure",
        [
          [:engram, :crypto, :kms, :request],
          [:engram, :crypto, :kms, :failure]
        ],
        fn name, _meas, meta, _ -> send(self(), {name, meta}) end,
        nil
      )

      try do
        assert {:error, :access_denied} =
                 KmsExAws.encrypt("pt", %{"user_id" => "1", "purpose" => "dek_wrap"})

        assert_received {[:engram, :crypto, :kms, :request],
                         %{op: :encrypt, status: :error, error_class: :access_denied}}

        assert_received {[:engram, :crypto, :kms, :failure],
                         %{op: :encrypt, error_class: :access_denied}}
      after
        :telemetry.detach("kms-failure")
      end
    end

    test "classifies a transport failure as :network_error", %{bypass: bypass} do
      # Regression guard for the hackney to Req swap: transport failures now
      # arrive as exception structs (for example %Mint.TransportError{}) rather
      # than hackney's bare :timeout / {:socket_error, _} atoms. Closing the
      # server forces a connection error through the real Req adapter.
      Bypass.down(bypass)

      prev_retries = Application.get_env(:ex_aws, :retries)
      Application.put_env(:ex_aws, :retries, max_attempts: 1)

      on_exit(fn ->
        if prev_retries,
          do: Application.put_env(:ex_aws, :retries, prev_retries),
          else: Application.delete_env(:ex_aws, :retries)
      end)

      :telemetry.attach_many(
        "kms-network-failure",
        [
          [:engram, :crypto, :kms, :request],
          [:engram, :crypto, :kms, :failure]
        ],
        fn name, _meas, meta, _ -> send(self(), {name, meta}) end,
        nil
      )

      try do
        assert {:error, :network_error} =
                 KmsExAws.encrypt("pt", %{"user_id" => "1", "purpose" => "dek_wrap"})

        assert_received {[:engram, :crypto, :kms, :request],
                         %{op: :encrypt, status: :error, error_class: :network_error}}

        assert_received {[:engram, :crypto, :kms, :failure],
                         %{op: :encrypt, error_class: :network_error}}
      after
        :telemetry.detach("kms-network-failure")
      end
    end

    test "emits :request and :failure with error_class :exception when the inner call raises" do
      prev_key_id = Application.get_env(:engram, :aws_kms_key_id)
      Application.delete_env(:engram, :aws_kms_key_id)

      :telemetry.attach_many(
        "kms-exception",
        [
          [:engram, :crypto, :kms, :request],
          [:engram, :crypto, :kms, :failure]
        ],
        fn name, _meas, meta, _ -> send(self(), {name, meta}) end,
        nil
      )

      try do
        assert_raise ArgumentError, fn ->
          KmsExAws.encrypt("pt", %{"user_id" => "1", "purpose" => "dek_wrap"})
        end

        assert_received {[:engram, :crypto, :kms, :request],
                         %{op: :encrypt, status: :error, error_class: :exception}}

        assert_received {[:engram, :crypto, :kms, :failure],
                         %{op: :encrypt, error_class: :exception}}
      after
        :telemetry.detach("kms-exception")
        if prev_key_id, do: Application.put_env(:engram, :aws_kms_key_id, prev_key_id)
      end
    end
  end
end
