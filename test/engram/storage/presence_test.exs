defmodule Engram.Storage.PresenceTest do
  @moduledoc """
  Characterisation of the blob presence probe (#2233): what each storage
  answer means, pinned so moving the probe from
  `ReconcileAttachmentBlobs.presence/2` into the shared `Storage.presence/1`
  changes none of it (docs/context/consolidation-drops-undocumented-tolerances.md).

  S3 classification, as `presence/2` did it: a 1-byte ranged GET.
    * 200 / 206 with a body: present
    * 200 with an EMPTY body: present
    * 416 range not satisfiable (a zero-byte object): present
    * 404: missing
    * 403, 500, a refused connection (timeout class): unknown, never missing
  """
  use ExUnit.Case, async: false

  @bucket "test-bucket"
  @key "u/v/objects/a"

  setup do
    bypass = Bypass.open()
    prev_s3 = Application.get_env(:ex_aws, :s3, [])
    prev_retries = Application.get_env(:ex_aws, :retries, [])
    prev_bucket = Application.get_env(:engram, :storage_bucket)
    prev_storage = Application.get_env(:engram, :storage)
    prev_access = Application.get_env(:ex_aws, :access_key_id)
    prev_secret = Application.get_env(:ex_aws, :secret_access_key)

    Application.put_env(:ex_aws, :s3,
      scheme: "http://",
      host: "localhost",
      port: bypass.port,
      region: "us-east-1"
    )

    Application.put_env(:ex_aws, :retries, max_attempts: 0)
    Application.put_env(:ex_aws, :access_key_id, "test-key")
    Application.put_env(:ex_aws, :secret_access_key, "test-secret")
    Application.put_env(:engram, :storage_bucket, @bucket)
    Application.put_env(:engram, :storage, Engram.Storage.S3)

    on_exit(fn ->
      Application.put_env(:ex_aws, :s3, prev_s3)
      Application.put_env(:ex_aws, :retries, prev_retries)
      Application.put_env(:engram, :storage, prev_storage)
      restore(:ex_aws, :access_key_id, prev_access)
      restore(:ex_aws, :secret_access_key, prev_secret)
      restore(:engram, :storage_bucket, prev_bucket)
    end)

    %{bypass: bypass}
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  # The probe under test. "Could not tell" was `:unknown` before the move
  # and is `{:error, _}` after; this normalises it so both pass.
  defp probe(key) do
    case Engram.Storage.presence(key) do
      {:error, _} -> :unknown
      other -> other
    end
  end

  defp answer(bypass, status, body) do
    Bypass.expect_once(bypass, "GET", "/#{@bucket}/#{@key}", fn conn ->
      Plug.Conn.resp(conn, status, body)
    end)
  end

  test "a body is present (200 and 206)", %{bypass: bypass} do
    answer(bypass, 206, "x")
    assert probe(@key) == :present
    answer(bypass, 200, "x")
    assert probe(@key) == :present
  end

  test "an empty 200 body is present", %{bypass: bypass} do
    answer(bypass, 200, "")
    assert probe(@key) == :present
  end

  test "416 (a zero-byte object cannot serve byte 0) is present", %{bypass: bypass} do
    answer(bypass, 416, "<Error><Code>InvalidRange</Code></Error>")
    assert probe(@key) == :present
  end

  test "404 is missing", %{bypass: bypass} do
    answer(bypass, 404, "<Error><Code>NoSuchKey</Code></Error>")
    assert probe(@key) == :missing
  end

  test "403 is unknown, not missing", %{bypass: bypass} do
    answer(bypass, 403, "<Error><Code>AccessDenied</Code></Error>")
    assert probe(@key) == :unknown
  end

  test "500 is unknown, not missing", %{bypass: bypass} do
    answer(bypass, 500, "")
    assert probe(@key) == :unknown
  end

  test "an unreachable store (timeout class) is unknown, not missing", %{bypass: bypass} do
    Bypass.down(bypass)
    assert probe(@key) == :unknown
  end

  # The test adapter answers like S3, so suites stubbed with it see the same.
  describe "on the InMemory test adapter" do
    test "present, a 0-byte object present, absent missing" do
      :ok = Engram.Storage.InMemory.put("p/a", "x", [])
      :ok = Engram.Storage.InMemory.put("p/empty", "", [])
      assert Engram.Storage.presence("p/a", Engram.Storage.InMemory) == :present
      assert Engram.Storage.presence("p/empty", Engram.Storage.InMemory) == :present
      assert Engram.Storage.presence("p/none", Engram.Storage.InMemory) == :missing
    end
  end
end
