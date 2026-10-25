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

  describe "delete_many/1" do
    test "returns the key count when the DeleteResult carries no errors", %{bypass: bypass} do
      xml =
        ~s(<?xml version="1.0"?><DeleteResult>) <>
          ~s(<Deleted><Key>a</Key></Deleted><Deleted><Key>b</Key></Deleted>) <>
          ~s(</DeleteResult>)

      Bypass.expect(bypass, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, xml)
      end)

      assert {:ok, 2} = S3.delete_many(["a", "b"])
    end

    test "surfaces per-key errors hidden in a 200 DeleteResult", %{bypass: bypass} do
      # S3 DeleteObjects returns HTTP 200 even when individual keys fail —
      # per-key failures ride the body as <Error> entries. Returning
      # length(keys) unconditionally hides leaked blobs.
      xml =
        ~s(<?xml version="1.0"?><DeleteResult>) <>
          ~s(<Deleted><Key>a</Key></Deleted>) <>
          ~s(<Error><Key>b</Key><Code>InternalError</Code><Message>boom</Message></Error>) <>
          ~s(</DeleteResult>)

      Bypass.expect(bypass, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, xml)
      end)

      {result, events} = LogCapture.with_events(fn -> S3.delete_many(["a", "b"]) end)

      assert result == {:ok, 1}

      event = Enum.find(events, fn e -> render_msg(e.msg) =~ "S3.delete_many partial failure" end)

      assert event, "expected an S3.delete_many partial-failure log event"
      assert event.level == :error
      assert event.meta[:category] == :sync
      assert event.meta[:key_count] == 2
      assert event.meta[:error_count] == 1
    end
  end

  describe "list_versions/2" do
    test "keeps versions and delete markers apart, across pages", %{bypass: bypass} do
      page = fn conn, body -> Plug.Conn.resp(conn, 200, body) end

      Bypass.expect(bypass, "GET", "/#{@bucket}/", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert Map.has_key?(conn.query_params, "versions")
        assert conn.query_params["prefix"] == "u/v/objects/"

        if conn.query_params["key-marker"] == "u/v/objects/a" do
          page.(conn, """
          <ListVersionsResult><IsTruncated>false</IsTruncated>
            <Version><Key>u/v/objects/b</Key><VersionId>b1</VersionId><IsLatest>true</IsLatest>
              <LastModified>2026-10-23T18:00:00.000Z</LastModified></Version>
          </ListVersionsResult>
          """)
        else
          page.(conn, """
          <ListVersionsResult><IsTruncated>true</IsTruncated>
            <NextKeyMarker>u/v/objects/a</NextKeyMarker><NextVersionIdMarker>a1</NextVersionIdMarker>
            <DeleteMarker><Key>u/v/objects/a</Key><VersionId>m1</VersionId><IsLatest>true</IsLatest>
              <LastModified>2026-10-24T00:38:00.000Z</LastModified></DeleteMarker>
            <Version><Key>u/v/objects/a</Key><VersionId>a1</VersionId><IsLatest>false</IsLatest>
              <LastModified>2026-10-23T18:00:00.000Z</LastModified></Version>
          </ListVersionsResult>
          """)
        end
      end)

      assert {:ok, first, next} = S3.list_versions("u/v/objects/", [])
      assert next == [key_marker: "u/v/objects/a", version_id_marker: "a1"]
      assert {:ok, second, nil} = S3.list_versions("u/v/objects/", marker: next)
      versions = first ++ second

      assert Enum.sort_by(versions, & &1.version_id) == [
               %{
                 key: "u/v/objects/a",
                 version_id: "a1",
                 last_modified: "2026-10-23T18:00:00.000Z",
                 latest?: false,
                 delete_marker?: false
               },
               %{
                 key: "u/v/objects/b",
                 version_id: "b1",
                 last_modified: "2026-10-23T18:00:00.000Z",
                 latest?: true,
                 delete_marker?: false
               },
               %{
                 key: "u/v/objects/a",
                 version_id: "m1",
                 last_modified: "2026-10-24T00:38:00.000Z",
                 latest?: true,
                 delete_marker?: true
               }
             ]
    end
  end

  test "list_versions/2 maps a backend without versioning (501) to {:unsupported, :not_implemented}",
       %{
         bypass: bypass
       } do
    Bypass.expect_once(bypass, "GET", "/#{@bucket}/", fn conn ->
      Plug.Conn.resp(conn, 501, "<Error><Code>NotImplemented</Code></Error>")
    end)

    assert {:error, {:unsupported, :not_implemented}} = S3.list_versions("u/v/objects/", [])
  end

  test "list_versions/2 maps AccessDenied (403) to {:unsupported, :access_denied}", %{
    bypass: bypass
  } do
    Bypass.expect_once(bypass, "GET", "/#{@bucket}/", fn conn ->
      Plug.Conn.resp(conn, 403, "<Error><Code>AccessDenied</Code><Message>no</Message></Error>")
    end)

    assert {:error, {:unsupported, :access_denied}} = S3.list_versions("u/v/objects/", [])
  end

  test "list_versions/2 keeps any other 403 an error", %{bypass: bypass} do
    Bypass.expect_once(bypass, "GET", "/#{@bucket}/", fn conn ->
      Plug.Conn.resp(conn, 403, "<Error><Code>SignatureDoesNotMatch</Code></Error>")
    end)

    assert {:error, {:http_error, 403, _}} = S3.list_versions("u/v/objects/", [])
  end

  describe "restore_version/2" do
    test "copies the version onto its own key with versionId in the source", %{bypass: bypass} do
      Bypass.expect_once(bypass, "PUT", "/#{@bucket}/u/v/objects/a", fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-amz-copy-source") ==
                 ["/#{@bucket}/u/v/objects/a?versionId=v%2B1"]

        Plug.Conn.resp(conn, 200, "<CopyObjectResult/>")
      end)

      assert :ok = S3.restore_version("u/v/objects/a", "v+1")
    end
  end

  describe "start_multipart/1" do
    test "returns the upload id parsed from the XML body", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/#{@bucket}/#{@key}", fn conn ->
        assert conn.query_string =~ "uploads"

        xml =
          ~s(<?xml version="1.0"?><InitiateMultipartUploadResult>) <>
            ~s(<Bucket>#{@bucket}</Bucket><Key>#{@key}</Key><UploadId>UP123</UploadId>) <>
            ~s(</InitiateMultipartUploadResult>)

        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, xml)
      end)

      assert {:ok, "UP123"} = S3.start_multipart(@key)
    end
  end

  describe "upload_part/4" do
    test "returns the etag from the response headers", %{bypass: bypass} do
      Bypass.expect_once(bypass, "PUT", "/#{@bucket}/#{@key}", fn conn ->
        assert conn.query_string =~ "partNumber=1"
        assert conn.query_string =~ "uploadId=UP123"

        conn
        |> Plug.Conn.put_resp_header("etag", ~s("etag-1"))
        |> Plug.Conn.resp(200, "")
      end)

      assert {:ok, ~s("etag-1")} = S3.upload_part(@key, "UP123", 1, <<1, 2, 3>>)
    end
  end

  describe "complete_multipart_upload/3" do
    test "returns :ok on success", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/#{@bucket}/#{@key}", fn conn ->
        assert conn.query_string =~ "uploadId=UP123"

        xml =
          ~s(<?xml version="1.0"?><CompleteMultipartUploadResult>) <>
            ~s(<Location>loc</Location><Bucket>#{@bucket}</Bucket><Key>#{@key}</Key>) <>
            ~s(<ETag>"final"</ETag></CompleteMultipartUploadResult>)

        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(200, xml)
      end)

      assert :ok =
               S3.complete_multipart_upload(@key, "UP123", [
                 %{part_number: 1, etag: ~s("etag-1")}
               ])
    end
  end

  describe "abort_multipart_upload/2" do
    test "returns :ok on success", %{bypass: bypass} do
      Bypass.expect_once(bypass, "DELETE", "/#{@bucket}/#{@key}", fn conn ->
        assert conn.query_string =~ "uploadId=UP123"
        Plug.Conn.resp(conn, 204, "")
      end)

      assert :ok = S3.abort_multipart_upload(@key, "UP123")
    end
  end

  defp render_msg({:string, s}), do: IO.iodata_to_binary(s)
  defp render_msg({:report, _}), do: ""
  defp render_msg(other), do: to_string(other)
end
