defmodule Engram.Storage.S3 do
  @moduledoc """
  S3-compatible storage adapter. Works with MinIO (local) and Fly Tigris (prod).
  """

  @behaviour Engram.Storage

  import SweetXml, only: [sigil_x: 2]

  alias Engram.Logger.Metadata

  defp bucket, do: Application.fetch_env!(:engram, :storage_bucket)

  @impl true
  def put(key, binary, opts \\ []) do
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")

    case ExAws.S3.put_object(bucket(), key, binary, content_type: content_type)
         |> ExAws.request() do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get(key) do
    case ExAws.S3.get_object(bucket(), key) |> ExAws.request() do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, {:http_error, 404, _}} -> {:error, :not_found}
      {:error, {:http_error, 404}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get_range(key, offset, length) do
    range = "bytes=#{offset}-#{offset + length - 1}"

    case ExAws.S3.get_object(bucket(), key, range: range) |> ExAws.request() do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, {:http_error, 404, _}} -> {:error, :not_found}
      {:error, {:http_error, 404}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(key) do
    case ExAws.S3.delete_object(bucket(), key) |> ExAws.request() do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete_prefix(prefix) when is_binary(prefix) and prefix != "" do
    case ExAws.S3.list_objects(bucket(), prefix: prefix) |> ExAws.request() do
      {:ok, %{body: %{contents: contents}}} ->
        keys = Enum.map(contents, & &1.key)
        delete_many(keys)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def delete_many([]), do: {:ok, 0}

  def delete_many(keys) do
    case ExAws.S3.delete_multiple_objects(bucket(), keys) |> ExAws.request() do
      {:ok, %{body: body}} ->
        # S3 DeleteObjects returns HTTP 200 even when individual keys fail —
        # failures ride the DeleteResult body as <Error> entries (ExAws has
        # no parser for this op, so `body` is the raw XML). Count them so a
        # partial failure is visible instead of reported as a full success.
        case count_delete_errors(body) do
          0 ->
            {:ok, length(keys)}

          error_count ->
            require Logger

            Logger.error(
              "S3.delete_many partial failure",
              Metadata.with_category(:error, :sync,
                key_count: length(keys),
                error_count: error_count
              )
            )

            {:ok, length(keys) - error_count}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Per-key failures in a DeleteResult body look like
  # <Error><Key>..</Key><Code>..</Code><Message>..</Message></Error>.
  defp count_delete_errors(xml) when is_binary(xml) do
    length(String.split(xml, "<Error>")) - 1
  end

  defp count_delete_errors(_), do: 0

  @impl true
  def list_versions(prefix, opts) when is_binary(prefix) and prefix != "" do
    marker = Keyword.get(opts, :marker) || []
    params = [prefix: prefix, max_keys: Keyword.get(opts, :max_keys, 1_000)] ++ marker
    # Parsed here: ExAws's parser crashes on an entry with no <Owner>.
    op = %{ExAws.S3.list_object_versions(bucket(), params) | parser: & &1}

    case ExAws.request(op) do
      {:ok, %{body: xml}} ->
        page = parse_versions(xml)

        next =
          if page.truncated?,
            do: [key_marker: page.next_key, version_id_marker: page.next_version]

        {:ok, page.versions, next}

      # Unsupported, not a failure to retry: S3-compatible stores without
      # versioning (Cloudflare R2, some MinIO modes) answer 501, and a role
      # without s3:ListBucketVersions (self-host, staging) answers 403
      # AccessDenied. Any other 403 (a bad signature) stays an error.
      {:error, {:http_error, 501, _}} ->
        {:error, {:unsupported, :not_implemented}}

      {:error, {:http_error, 403, %{body: body}} = reason} ->
        if is_binary(body) and body =~ "<Code>AccessDenied</Code>",
          do: {:error, {:unsupported, :access_denied}},
          else: {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_versions(xml) do
    entry = [
      key: ~x"./Key/text()"s,
      version_id: ~x"./VersionId/text()"s,
      is_latest: ~x"./IsLatest/text()"s,
      # ISO 8601 UTC, all the same width, so string order is time order.
      last_modified: ~x"./LastModified/text()"s
    ]

    page =
      SweetXml.xpath(xml, ~x"//ListVersionsResult",
        truncated: ~x"./IsTruncated/text()"s,
        next_key: ~x"./NextKeyMarker/text()"s,
        next_version: ~x"./NextVersionIdMarker/text()"s,
        versions: [~x"./Version"l | entry],
        markers: [~x"./DeleteMarker"l | entry]
      )

    %{
      truncated?: page.truncated == "true",
      next_key: page.next_key,
      next_version: page.next_version,
      versions:
        Enum.map(page.versions, &version(&1, false)) ++ Enum.map(page.markers, &version(&1, true))
    }
  end

  defp version(v, marker?),
    do: %{
      key: v.key,
      version_id: v.version_id,
      last_modified: v.last_modified,
      latest?: v.is_latest == "true",
      delete_marker?: marker?
    }

  # CopyObject onto the same key, built by hand: `ExAws.S3.put_object_copy/5`
  # URL-encodes the whole source, so a `?versionId=` cannot be passed. Keys
  # are `<uuid>/<uuid>/objects/<uuid>`, so segment-encoding them is exact.
  # One CopyObject handles up to 5 GB, above any attachment size cap.
  @impl true
  def restore_version(key, version_id) do
    source =
      "/" <>
        Enum.map_join([bucket() | String.split(key, "/")], "/", fn segment ->
          URI.encode(segment, &URI.char_unreserved?/1)
        end) <>
        "?versionId=" <> URI.encode_www_form(version_id)

    %ExAws.Operation.S3{
      http_method: :put,
      bucket: bucket(),
      path: key,
      headers: %{"x-amz-copy-source" => source}
    }
    |> ExAws.request()
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list_user_prefixes do
    case ExAws.S3.list_objects(bucket(), delimiter: "/") |> ExAws.request() do
      {:ok, %{body: %{common_prefixes: prefixes}}} ->
        ids =
          prefixes
          |> Enum.map(& &1.prefix)
          |> Enum.flat_map(&parse_user_id_from_prefix/1)

        {:ok, ids}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_user_id_from_prefix(prefix) do
    case Ecto.UUID.cast(String.trim_trailing(prefix, "/")) do
      {:ok, id} -> [id]
      :error -> []
    end
  end

  @impl true
  def selfhost?, do: false

  @impl true
  def multipart?, do: true

  @impl true
  def sign_url(key, opts) when is_binary(key) and is_list(opts) do
    ttl = Keyword.fetch!(opts, :ttl)

    {:ok, url} =
      ExAws.Config.new(:s3)
      |> ExAws.S3.presigned_url(:get, bucket(), key, expires_in: ttl)

    url
  end

  @impl true
  def start_multipart(key) when is_binary(key) do
    case ExAws.S3.initiate_multipart_upload(bucket(), key) |> ExAws.request() do
      {:ok, %{body: %{upload_id: upload_id}}} when is_binary(upload_id) and upload_id != "" ->
        {:ok, upload_id}

      {:ok, other} ->
        {:error, {:no_upload_id, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def upload_part(key, upload_id, part_number, chunk)
      when is_binary(key) and is_binary(upload_id) and is_integer(part_number) and
             part_number > 0 and is_binary(chunk) do
    case ExAws.S3.upload_part(bucket(), key, upload_id, part_number, chunk) |> ExAws.request() do
      {:ok, %{headers: headers}} ->
        case fetch_etag(headers) do
          nil -> {:error, :no_etag}
          etag -> {:ok, etag}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def complete_multipart_upload(key, upload_id, parts)
      when is_binary(key) and is_binary(upload_id) and is_list(parts) do
    tuple_parts =
      parts
      |> Enum.map(fn %{part_number: n, etag: etag} -> {n, etag} end)
      |> Enum.sort_by(&elem(&1, 0))

    case ExAws.S3.complete_multipart_upload(bucket(), key, upload_id, tuple_parts)
         |> ExAws.request() do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def abort_multipart_upload(key, upload_id) when is_binary(key) and is_binary(upload_id) do
    case ExAws.S3.abort_multipart_upload(bucket(), key, upload_id) |> ExAws.request() do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_etag(headers) when is_list(headers) do
    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(to_string(k)) == "etag", do: v
    end)
  end

  defp fetch_etag(_), do: nil
end
