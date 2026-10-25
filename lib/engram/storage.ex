defmodule Engram.Storage do
  @moduledoc """
  Behaviour for S3-compatible file storage backends (MinIO local, Tigris prod).
  All keys are scoped by user_id and vault_id prefix: "user_id/vault_id/path".
  """

  @callback put(key :: String.t(), binary :: binary(), opts :: keyword()) ::
              :ok | {:error, term()}

  @callback get(key :: String.t()) ::
              {:ok, binary()} | {:error, :not_found | term()}

  @doc """
  Reads `length` bytes of `key` starting at byte `offset` (an S3 ranged GET).
  Lets a segmented (format v2) attachment be read one segment at a time.
  """
  @callback get_range(key :: String.t(), offset :: non_neg_integer(), length :: pos_integer()) ::
              {:ok, binary()} | {:error, :not_found | term()}

  @callback delete(key :: String.t()) ::
              :ok | {:error, term()}

  @doc """
  Deletes many objects in one backend round trip where the backend supports
  it (S3 `DeleteObjects`). Used by `Engram.Attachments.batch_delete/3` so a
  500-path batch doesn't issue 500 sequential DELETE calls. Best-effort like
  `delete/1` — callers treat failure as a zombie-blob warning, never data loss.
  """
  @callback delete_many(keys :: [String.t()]) ::
              {:ok, non_neg_integer()} | {:error, term()}

  @typedoc """
  One entry of a versioned bucket's history. `last_modified` orders a key's
  entries (newest is greatest); `latest?` marks the current one.
  """
  @type version :: %{
          key: String.t(),
          version_id: String.t(),
          last_modified: term(),
          latest?: boolean(),
          delete_marker?: boolean()
        }

  @doc """
  One page of the versions and delete markers under `prefix` (S3
  `ListObjectVersions`), at most `opts[:max_keys]` (default 1,000) entries,
  in key order. Returns the page and the `next` marker to pass back as
  `opts[:marker]`, or nil on the last page. A key's entries may span two
  pages. Used by `Engram.Workers.ReconcileAttachmentBlobs` to find a live
  row's blob behind a delete marker, a page at a time. `{:error,
  :unsupported}` (or `{:error, {:unsupported, reason}}`) when versions cannot
  be listed here at all, which makes the reconciler a no-op: a backend
  without versioning, or a role without the list permission.
  """
  @callback list_versions(prefix :: String.t(), opts :: keyword()) ::
              {:ok, [version()], next :: term() | nil}
              | {:error, :unsupported | {:unsupported, atom()} | term()}

  @doc """
  Makes `version_id` of `key` its current version again by copying it on top
  (a new version). Never deletes a version or marker, so the app needs no
  permanent-delete permission.
  """
  @callback restore_version(key :: String.t(), version_id :: String.t()) ::
              :ok | {:error, :unsupported | term()}

  @callback delete_prefix(prefix :: String.t()) ::
              {:ok, non_neg_integer()} | {:error, term()}

  @doc """
  Enumerates the top-level user_id prefixes in the bucket (one per active
  user). Used by `Engram.Workers.OrphanSweep` to diff against the live
  users table without listing every blob.
  """
  @callback list_user_prefixes() ::
              {:ok, [non_neg_integer()]} | {:error, term()}

  @doc """
  Whether this adapter is a self-host backend that cannot mint pre-signed
  download URLs (Postgres `bytea`; anything that requires the application
  process to stream bytes itself). Used by `Engram.Accounts.Export` to
  decide between handing the client a URL vs streaming via the controller.

  The S3 adapter returns `false` even when fronted by self-host MinIO —
  presigning works there. Only adapters that genuinely cannot presign
  (`Database`, in-memory test stub) return `true`.
  """
  @callback selfhost?() :: boolean()

  @doc """
  Mint a short-lived signed download URL for `key`. Required `:ttl` option
  (seconds) bounds the URL's lifetime. Only callable on adapters where
  `selfhost?/0` returns `false`; selfhost adapters raise.
  """
  @callback sign_url(key :: String.t(), opts :: keyword()) :: String.t()

  # ── Multipart upload ────────────────────────────────────────────────
  #
  # Used by `Engram.Accounts.Export.Streamer` to stream account-export
  # archives into S3 without ever buffering a whole part in memory. The
  # part list returned by `complete_multipart_upload/3` is a list of
  # `%{part_number: integer, etag: binary}` maps in ascending part order.
  #
  # Selfhost adapters (`Database`) raise on the multipart calls —
  # account export on selfhost streams bytes through the controller
  # directly (see Task 22) and never goes through this code path.

  @callback start_multipart(key :: String.t()) ::
              {:ok, upload_id :: String.t()} | {:error, term()}

  @callback upload_part(
              key :: String.t(),
              upload_id :: String.t(),
              part_number :: pos_integer(),
              chunk :: binary()
            ) :: {:ok, etag :: String.t()} | {:error, term()}

  @callback complete_multipart_upload(
              key :: String.t(),
              upload_id :: String.t(),
              parts :: [map()]
            ) :: :ok | {:error, term()}

  @callback abort_multipart_upload(key :: String.t(), upload_id :: String.t()) ::
              :ok | {:error, term()}

  @doc """
  Whether this adapter supports the multipart calls above. Gates the chunked
  attachment upload feature advertised to clients; `Database` cannot, so a
  self-host on Postgres keeps single-request uploads.
  """
  @callback multipart?() :: boolean()

  @doc "Returns the configured storage adapter module."
  def adapter, do: Application.get_env(:engram, :storage, __MODULE__.S3)

  @doc """
  Whether `key` holds an object: `:present`, `:missing`, or `{:error, reason}`
  when the store could not answer. An error is "unknown", never "missing":
  a caller that read it as absent finalized rows whose blob was still there
  (#2233). The one presence check; there is no boolean `exists?`.

  A one-byte ranged GET, on any adapter. A 0-byte object cannot serve byte 0:
  S3 answers 416 InvalidRange. It exists, so it is present. Sealed objects are
  never empty; this keeps the edge from reading as a failure.
  """
  @spec presence(String.t(), module()) :: :present | :missing | {:error, term()}
  def presence(key, adapter \\ adapter()) when is_binary(key) do
    case adapter.get_range(key, 0, 1) do
      {:ok, _} -> :present
      {:error, :not_found} -> :missing
      {:error, {:http_error, 416, _}} -> :present
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Build an attachment blob key from a UUID: a fresh one per stored blob
  (single-request writes) or the upload id (chunked uploads), never the
  path. Decoupled from the mutable vault path so move/rename never relocates
  the blob; fresh per write so a write never clobbers a blob a live row still
  reads. Readers always go through the row's `storage_key`.

  This is the only key builder for attachments; `revision_key/4` below is the only one for note versions. `key/3`, which produced
  `"user/vault/<cleartext path>"`, is deleted — a storage key ends up in the S3
  URL and therefore in S3 access logs, CDN logs and bucket listings, none of
  which any control in this codebase can reach, so the path must not be in the
  key at all.

  Prod was counted on 2026-08-17 before that deletion shipped: 129 attachments
  across 6 tenants, ALL UUID-keyed, zero path-derived and zero NULL. So there
  is no legacy population to migrate; the previous note here, that "legacy rows
  keep their path-derived `storage_key`", described rows that do not exist.
  """
  def object_key(user_id, vault_id, att_id)
      when is_binary(user_id) and is_binary(vault_id) and is_binary(att_id) and att_id != "" do
    "#{user_id}/#{vault_id}/objects/#{att_id}"
  end

  @doc """
  Storage key for a note version's blob (#1710).

  Top-level `revisions/` rather than under `<user_id>/`: S3 lifecycle filters
  only match from the start of a key, and the bucket keeps noncurrent versions,
  so this object class needs its own rule (#1714), the same way `exports/`
  has one. Every segment is a UUID, so no plaintext reaches storage URLs or
  access logs, and `revisions` can never equal a user id, so these keys cannot
  collide with `<user_id>/<vault_id>/objects/...`.

  `Engram.Storage.S3.list_user_prefixes/0` skips this prefix (it is not a
  UUID), so the orphan sweep does not see these blobs until #1715 teaches it to.
  """
  def revision_key(user_id, vault_id, note_id, revision_id)
      when is_binary(user_id) and is_binary(vault_id) and is_binary(note_id) and
             is_binary(revision_id) do
    "revisions/#{user_id}/#{vault_id}/#{note_id}/#{revision_id}"
  end
end
