defmodule Engram.Storage.Database do
  @moduledoc """
  Postgres `bytea` storage adapter for the minified self-host stack (#297).

  Opt-in via `STORAGE_BACKEND=database`. Stores attachment bytes in the
  `storage_objects` table keyed by the same `user_id/vault_id/path` storage_key
  the S3 adapter uses, so a self-hoster can drop MinIO. SaaS/prod is unchanged
  (stays `Engram.Storage.S3` on Fly Tigris).

  Values are opaque — the caller already hands `put/3` ciphertext, so at-rest
  encryption is inherited for free. `storage_objects` is intentionally NOT a
  tenant-scoped table (see `Engram.Repo`); scoping is by storage_key prefix,
  matching S3, and these calls run outside any tenant transaction.

  Suited to modest self-host vaults only — large blobs bloat Postgres + WAL
  (bytea TOAST caps ~1 GB/value), which is why bytea was removed for SaaS
  (A.5 / PR #62).
  """

  @behaviour Engram.Storage

  alias Engram.Repo

  # Escape char for LIKE patterns so a storage_key containing `_`/`%` (paths
  # may) is matched literally in delete_prefix/1.
  @like_escape "\\"

  @impl true
  def put(key, binary, _opts \\ []) when is_binary(key) and is_binary(binary) do
    now = DateTime.utc_now(:microsecond)

    _ =
      Repo.query!(
        """
        INSERT INTO storage_objects (storage_key, data, byte_size, inserted_at)
        VALUES ($1, $2, $3, $4)
        ON CONFLICT (storage_key)
        DO UPDATE SET data = EXCLUDED.data, byte_size = EXCLUDED.byte_size
        """,
        [key, binary, byte_size(binary), now]
      )

    :ok
  rescue
    e -> {:error, e}
  end

  @impl true
  def get(key) when is_binary(key) do
    case Repo.query!("SELECT data FROM storage_objects WHERE storage_key = $1", [key]) do
      %{rows: [[data]]} -> {:ok, data}
      %{rows: []} -> {:error, :not_found}
    end
  rescue
    e -> {:error, e}
  end

  @impl true
  def delete(key) when is_binary(key) do
    _ = Repo.query!("DELETE FROM storage_objects WHERE storage_key = $1", [key])
    :ok
  rescue
    e -> {:error, e}
  end

  @impl true
  def exists?(key) when is_binary(key) do
    case Repo.query!("SELECT 1 FROM storage_objects WHERE storage_key = $1 LIMIT 1", [key]) do
      %{rows: [[1]]} -> true
      %{rows: []} -> false
    end
  rescue
    _ -> false
  end

  @impl true
  def delete_prefix(prefix) when is_binary(prefix) and prefix != "" do
    pattern = escape_like(prefix) <> "%"

    %{num_rows: count} =
      Repo.query!(
        "DELETE FROM storage_objects WHERE storage_key LIKE $1 ESCAPE $2",
        [pattern, @like_escape]
      )

    {:ok, count}
  rescue
    e -> {:error, e}
  end

  @impl true
  def selfhost?, do: true

  # Multipart upload + presigned URLs are S3-only. Selfhost streams the
  # archive through the controller (see Task 22) and never reaches these
  # callbacks. They raise loudly so a misrouted call surfaces during
  # development instead of silently writing nothing.
  @dialyzer {:nowarn_function,
             sign_url: 2,
             start_multipart: 1,
             upload_part: 4,
             complete_multipart_upload: 3,
             abort_multipart_upload: 2}

  @impl true
  def sign_url(_key, _opts) do
    raise "Engram.Storage.Database.sign_url/2 — selfhost storage cannot presign; stream via controller"
  end

  @impl true
  def start_multipart(_key) do
    raise "Engram.Storage.Database.start_multipart/1 — selfhost storage does not support multipart upload; stream via controller"
  end

  @impl true
  def upload_part(_key, _upload_id, _part_number, _chunk) do
    raise "Engram.Storage.Database.upload_part/4 — selfhost storage does not support multipart upload"
  end

  @impl true
  def complete_multipart_upload(_key, _upload_id, _parts) do
    raise "Engram.Storage.Database.complete_multipart_upload/3 — selfhost storage does not support multipart upload"
  end

  @impl true
  def abort_multipart_upload(_key, _upload_id) do
    raise "Engram.Storage.Database.abort_multipart_upload/2 — selfhost storage does not support multipart upload"
  end

  @impl true
  def list_user_prefixes do
    %{rows: rows} =
      Repo.query!("SELECT DISTINCT split_part(storage_key, '/', 1) FROM storage_objects", [])

    ids =
      Enum.flat_map(rows, fn [segment] ->
        case Integer.parse(segment) do
          {id, ""} -> [id]
          _ -> []
        end
      end)

    {:ok, ids}
  rescue
    e -> {:error, e}
  end

  defp escape_like(value) do
    value
    |> String.replace(@like_escape, @like_escape <> @like_escape)
    |> String.replace("%", @like_escape <> "%")
    |> String.replace("_", @like_escape <> "_")
  end
end
