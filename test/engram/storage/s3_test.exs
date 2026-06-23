defmodule Engram.Storage.S3Test do
  use ExUnit.Case, async: false

  alias Engram.Storage.S3
  alias Engram.Test.LogCapture

  @bucket "test-bucket"
  @key "user123/photos/test.png"
  @binary <<137, 80, 78, 71, 13, 10, 26, 10>>

  setup do
    bypass = Bypass.open()

    # Save previous config
    prev_s3 = Application.get_env(:ex_aws, :s3, [])
    prev_retries = Application.get_env(:ex_aws, :retries, [])
    prev_access = Application.get_env(:ex_aws, :access_key_id, nil)
    prev_secret = Application.get_env(:ex_aws, :secret_access_key, nil)
    prev_bucket = Application.get_env(:engram, :storage_bucket, nil)

    # Configure ExAws to point at bypass with no retries
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

    on_exit(fn ->
      Application.put_env(:ex_aws, :s3, prev_s3)
      Application.put_env(:ex_aws, :retries, prev_retries)

      if prev_access,
        do: Application.put_env(:ex_aws, :access_key_id, prev_access),
        else: Application.delete_env(:ex_aws, :access_key_id)

      if prev_secret,
        do: Application.put_env(:ex_aws, :secret_access_key, prev_secret),
        else: Application.delete_env(:ex_aws, :secret_access_key)

      if prev_bucket,
        do: Application.put_env(:engram, :storage_bucket, prev_bucket),
        else: Application.delete_env(:engram, :storage_bucket)
    end)

    %{bypass: bypass}
  end

  describe "put/3" do
    test "uploads object to S3", %{bypass: bypass} do
      Bypass.expect_once(bypass, "PUT", "/#{@bucket}/#{@key}", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body == @binary
        Plug.Conn.resp(conn, 200, "")
      end)

      assert :ok = S3.put(@key, @binary)
    end

    test "passes content_type option", %{bypass: bypass} do
      Bypass.expect_once(bypass, "PUT", "/#{@bucket}/#{@key}", fn conn ->
        content_type =
          Enum.find_value(conn.req_headers, fn
            {"content-type", val} -> val
            _ -> nil
          end)

        assert content_type =~ "image/png"
        Plug.Conn.resp(conn, 200, "")
      end)

      assert :ok = S3.put(@key, @binary, content_type: "image/png")
    end

    test "returns error on failure", %{bypass: bypass} do
      Bypass.expect(bypass, "PUT", "/#{@bucket}/#{@key}", fn conn ->
        Plug.Conn.resp(conn, 500, "Internal Server Error")
      end)

      assert {:error, _} = S3.put(@key, @binary)
    end
  end

  describe "get/1" do
    test "returns binary on success", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/#{@bucket}/#{@key}", fn conn ->
        Plug.Conn.resp(conn, 200, @binary)
      end)

      assert {:ok, @binary} = S3.get(@key)
    end

    test "returns :not_found on 404", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/#{@bucket}/#{@key}", fn conn ->
        Plug.Conn.resp(conn, 404, "<Error><Code>NoSuchKey</Code></Error>")
      end)

      assert {:error, :not_found} = S3.get(@key)
    end

    test "returns error on other failures", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/#{@bucket}/#{@key}", fn conn ->
        Plug.Conn.resp(conn, 500, "Internal Server Error")
      end)

      assert {:error, _} = S3.get(@key)
    end
  end

  describe "delete/1" do
    test "deletes object from S3", %{bypass: bypass} do
      Bypass.expect_once(bypass, "DELETE", "/#{@bucket}/#{@key}", fn conn ->
        Plug.Conn.resp(conn, 204, "")
      end)

      assert :ok = S3.delete(@key)
    end

    test "returns error on failure", %{bypass: bypass} do
      Bypass.expect(bypass, "DELETE", "/#{@bucket}/#{@key}", fn conn ->
        Plug.Conn.resp(conn, 500, "Internal Server Error")
      end)

      assert {:error, _} = S3.delete(@key)
    end
  end

  describe "exists?/1" do
    test "returns true when object exists", %{bypass: bypass} do
      Bypass.expect_once(bypass, "HEAD", "/#{@bucket}/#{@key}", fn conn ->
        Plug.Conn.resp(conn, 200, "")
      end)

      assert S3.exists?(@key) == true
    end

    test "returns false when object does not exist", %{bypass: bypass} do
      Bypass.expect_once(bypass, "HEAD", "/#{@bucket}/#{@key}", fn conn ->
        Plug.Conn.resp(conn, 404, "")
      end)

      assert S3.exists?(@key) == false
    end

    test "logs a shippable :sync error on non-404 failure", %{bypass: bypass} do
      Bypass.expect_once(bypass, "HEAD", "/#{@bucket}/#{@key}", fn conn ->
        Plug.Conn.resp(conn, 500, "")
      end)

      {result, events} = LogCapture.with_events(fn -> S3.exists?(@key) end)

      assert result == false

      event = Enum.find(events, fn e -> render_msg(e.msg) =~ "S3.exists? failed" end)

      assert event, "expected an S3.exists? failure log event"
      assert event.level == :error
      assert event.meta[:category] == :sync
      assert event.meta[:loki_ship] == true
      # storage_key is a redacted metadata key (embeds user/vault ids), so the
      # filter scrubs it before the sink — assert it's present-but-redacted
      # rather than leaking the raw key.
      assert event.meta[:storage_key] == "[REDACTED]"
    end
  end

  defp render_msg({:string, s}), do: IO.iodata_to_binary(s)
  defp render_msg({:report, _}), do: ""
  defp render_msg(other), do: to_string(other)
end
