defmodule Engram.Workers.QdrantPayloadPhaseB do
  @moduledoc """
  Phase B.2.5 — re-shapes existing Qdrant payloads with the Phase B HMAC keys
  (`path_hmac` / `folder_hmac` / `tags_hmac`) so the B.2.3 read switch can
  filter by them. PATCHes payloads via `Qdrant.set_payload/3` instead of
  re-upserting full points: vectors are not touched, no Voyage cost.

  Cursor-driven per (user, vault), batch of 100 notes per invocation. Reads
  HMAC bytes straight off the note row (B.1 backfill is the source of truth)
  and base64-encodes them for JSON-safe transport — same encoding that
  `Engram.Indexing.build_prepared/4` uses for fresh writes (B.2.4).

  Idempotent on retry: the cursor advances over note ids, and a re-PATCH with
  identical payload is a no-op on the Qdrant side.
  """

  use Oban.Worker,
    queue: :crypto_backfill,
    max_attempts: 5,
    # `executing` excluded so self-reenqueue from inside `perform/1` isn't
    # flagged as a duplicate — same hazard documented in BackfillPhaseBHmac.
    unique: [keys: [:user_id, :vault_id], states: [:available, :scheduled]]

  import Ecto.Query

  alias Engram.Notes.{Chunk, Note}
  alias Engram.Repo
  alias Engram.Vector.Qdrant

  @batch_size 100

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "vault_id" => vault_id} = args}) do
    last_id = Map.get(args, "last_id", 0)

    {:ok, cursor_result} =
      Repo.with_tenant(user_id, fn ->
        process_batch(user_id, vault_id, last_id)
      end)

    case cursor_result do
      {:done, _last} ->
        :ok

      {:error, _} = err ->
        err

      {:more, next_cursor} ->
        %{"user_id" => user_id, "vault_id" => vault_id, "last_id" => next_cursor}
        |> __MODULE__.new()
        |> Oban.insert()

        :ok
    end
  end

  defp process_batch(user_id, vault_id, last_id) do
    notes =
      from(n in Note,
        where: n.user_id == ^user_id and n.vault_id == ^vault_id and n.id > ^last_id,
        order_by: [asc: n.id],
        limit: @batch_size
      )
      |> Repo.all()

    case Enum.reduce_while(notes, :ok, &patch_note/2) do
      :ok ->
        case notes do
          [] -> {:done, last_id}
          _ -> {:more, List.last(notes).id}
        end

      {:error, _} = err ->
        err
    end
  end

  defp patch_note(%Note{} = note, _acc) do
    point_ids =
      from(c in Chunk,
        where: c.note_id == ^note.id and not is_nil(c.qdrant_point_id),
        select: c.qdrant_point_id
      )
      |> Repo.all(skip_tenant_check: true)

    case point_ids do
      [] ->
        {:cont, :ok}

      ids ->
        case Qdrant.set_payload(nil, ids, build_payload(note)) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end
    end
  end

  # Pre-Phase-B-1 rows have nil HMACs; backfill must run first. Skip the
  # absent fields rather than write nil — that would poison filters with a
  # null match. `encode_hmac/1` mirrors the encoding in `Indexing.build_prepared/4`.
  defp build_payload(%Note{} = note) do
    %{}
    |> maybe_put(:path_hmac, encode_hmac(note.path_hmac))
    |> maybe_put(:folder_hmac, encode_hmac(note.folder_hmac))
    |> maybe_put(:tags_hmac, encode_tags_hmac(note.tags_hmac))
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  defp encode_hmac(nil), do: nil
  defp encode_hmac(bin) when is_binary(bin), do: Base.encode64(bin)

  defp encode_tags_hmac(nil), do: nil
  defp encode_tags_hmac([]), do: []
  defp encode_tags_hmac(list) when is_list(list), do: Enum.map(list, &Base.encode64/1)
end
