defmodule Engram.Storage.InMemory do
  @moduledoc """
  ETS-backed in-memory storage adapter for tests.

  Default stub for `Engram.MockStorage` — tests that need to assert on
  storage interactions still use `Mox.expect/3` directly; tests that
  just want a working backend get pass-through behaviour for free.
  """

  @behaviour Engram.Storage

  @table :engram_test_storage_in_memory
  # Version history, like a versioned S3 bucket: every put adds a data
  # version, every delete a delete marker. `{key, {seq, version}}` rows in a
  # bag; `seq` is monotonic, so the highest is the latest.
  @versions :engram_test_storage_in_memory_versions

  @doc """
  Ensures the blob and multipart ETS tables exist. Idempotent and safe to
  call concurrently.

  An ETS table dies with the process that created it, so `test_helper.exs`
  calls this once to make the suite runner the owner. Otherwise the first
  test to store a blob owns the tables, and its exit wipes every concurrent
  test's blobs (`{:storage, :blob_missing}`).
  """
  def ensure_table do
    ensure_multipart_table()
    ensure_versions_table()

    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:public, :named_table, :set])
          :ok
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  @impl true
  def put(key, binary, _opts \\ []) do
    ensure_table()
    :ets.insert(@table, {key, binary})
    add_version(key, {:data, binary})
    :ok
  end

  @impl true
  def get(key) do
    ensure_table()

    case :ets.lookup(@table, key) do
      [{^key, binary}] -> {:ok, binary}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def get_range(key, offset, length) do
    with {:ok, binary} <- get(key) do
      if offset + length <= byte_size(binary),
        do: {:ok, binary_part(binary, offset, length)},
        else: {:error, :invalid_range}
    end
  end

  @impl true
  def delete(key) do
    ensure_table()
    :ets.delete(@table, key)
    add_version(key, :delete_marker)
    :ok
  end

  @impl true
  def delete_many(keys) when is_list(keys) do
    Enum.each(keys, &delete/1)
    {:ok, length(keys)}
  end

  @impl true
  def list_versions(prefix) do
    ensure_table()

    versions =
      :ets.foldl(
        fn {key, {seq, version}}, acc ->
          if String.starts_with?(key, prefix), do: [{key, seq, version} | acc], else: acc
        end,
        [],
        @versions
      )

    latest =
      Enum.reduce(versions, %{}, fn {k, seq, _}, acc -> Map.update(acc, k, seq, &max(&1, seq)) end)

    {:ok,
     for {key, seq, version} <- versions do
       %{
         key: key,
         version_id: Integer.to_string(seq),
         last_modified: seq,
         latest?: latest[key] == seq,
         delete_marker?: version == :delete_marker
       }
     end}
  end

  @impl true
  def restore_version(key, version_id) do
    ensure_table()
    seq = String.to_integer(version_id)

    case Enum.find(:ets.lookup(@versions, key), &match?({_, {^seq, {:data, _}}}, &1)) do
      {_, {_, {:data, binary}}} -> put(key, binary)
      nil -> {:error, :not_found}
    end
  end

  defp add_version(key, version),
    do: :ets.insert(@versions, {key, {System.unique_integer([:monotonic, :positive]), version}})

  defp ensure_versions_table do
    case :ets.whereis(@versions) do
      :undefined ->
        try do
          :ets.new(@versions, [:public, :named_table, :bag])
          :ok
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  @impl true
  def exists?(key) do
    ensure_table()
    :ets.member(@table, key)
  end

  @impl true
  def delete_prefix(prefix) do
    ensure_table()

    keys =
      :ets.foldl(
        fn {k, _}, acc -> if String.starts_with?(k, prefix), do: [k | acc], else: acc end,
        [],
        @table
      )

    Enum.each(keys, &delete/1)
    {:ok, length(keys)}
  end

  @impl true
  def selfhost?, do: true

  @impl true
  def multipart?, do: true

  @impl true
  def sign_url(_key, _opts) do
    raise "Engram.Storage.InMemory.sign_url/2 — test stub does not presign"
  end

  # ── Multipart upload (test impl) ────────────────────────────────────
  #
  # Buffers chunks under a separate ETS row keyed by
  # `{:multipart, key, upload_id}`. `complete_multipart_upload/3`
  # concatenates the parts (in part_number order) into the final value
  # under `key` exactly like a real S3 backend would. Tests can introspect
  # the final blob via `get/1`.

  @multipart_table :engram_test_storage_in_memory_multipart

  defp ensure_multipart_table do
    case :ets.whereis(@multipart_table) do
      :undefined ->
        try do
          :ets.new(@multipart_table, [:public, :named_table, :set])
          :ok
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  @impl true
  def start_multipart(key) when is_binary(key) do
    ensure_multipart_table()
    upload_id = "in-memory-upload-" <> Base.encode16(:crypto.strong_rand_bytes(8))
    :ets.insert(@multipart_table, {{:multipart, key, upload_id}, %{}})
    {:ok, upload_id}
  end

  @impl true
  def upload_part(key, upload_id, part_number, chunk)
      when is_binary(key) and is_binary(upload_id) and is_integer(part_number) and
             part_number > 0 and is_binary(chunk) do
    ensure_multipart_table()
    handle = {:multipart, key, upload_id}

    case :ets.lookup(@multipart_table, handle) do
      [{^handle, parts}] ->
        :ets.insert(@multipart_table, {handle, Map.put(parts, part_number, chunk)})

        etag =
          chunk
          |> then(&:crypto.hash(:md5, &1))
          |> Base.encode16(case: :lower)

        {:ok, "\"" <> etag <> "\""}

      [] ->
        {:error, :no_such_upload}
    end
  end

  @impl true
  def complete_multipart_upload(key, upload_id, parts)
      when is_binary(key) and is_binary(upload_id) and is_list(parts) do
    ensure_multipart_table()
    handle = {:multipart, key, upload_id}

    case :ets.lookup(@multipart_table, handle) do
      [{^handle, stored}] ->
        # Mirror S3: every part but the last must be at least 5 MiB, so tests
        # catch an undersized-part bug that only real storage would reject.
        numbers = parts |> Enum.map(& &1.part_number) |> Enum.sort()

        if Enum.any?(Enum.drop(numbers, -1), &(byte_size(Map.fetch!(stored, &1)) < 5_242_880)) do
          {:error, :entity_too_small}
        else
          assemble(key, handle, stored, numbers)
        end

      [] ->
        {:error, :no_such_upload}
    end
  end

  defp assemble(key, handle, stored, numbers) do
    put(key, numbers |> Enum.map(&Map.fetch!(stored, &1)) |> IO.iodata_to_binary())
    :ets.delete(@multipart_table, handle)
    :ok
  end

  @impl true
  def abort_multipart_upload(key, upload_id) when is_binary(key) and is_binary(upload_id) do
    ensure_multipart_table()
    :ets.delete(@multipart_table, {:multipart, key, upload_id})
    :ok
  end

  @impl true
  def list_user_prefixes do
    ensure_table()

    ids =
      :ets.foldl(
        fn {k, _}, acc ->
          case String.split(k, "/", parts: 2) do
            [user_id_str, _rest] ->
              case Ecto.UUID.cast(user_id_str) do
                {:ok, id} -> [id | acc]
                :error -> acc
              end

            _ ->
              acc
          end
        end,
        [],
        @table
      )

    {:ok, Enum.uniq(ids)}
  end
end
