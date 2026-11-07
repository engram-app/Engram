defmodule Engram.Folders.Wire do
  @moduledoc """
  The plugin's folder-op wire (#2523, stage S4), behind the `folder_ops`
  runtime switch (`Engram.ServiceConfig`, default off; staging turns it on
  with `ServiceConfig.override(:folder_ops, true)`, no deploy).

  `enabled?/0` is the ONE read of the switch: the join reply's
  `features.folder_ops` (`EngramWeb.UserChannel.features/0`), the inbound
  `folder_op` frame (`EngramWeb.CrdtChannel`) and the outbound events below
  all go through it, so with it off the server behaves exactly as before.

  Inbound, `folder_op {op, op_id, folder_id, parent_id, name}` (`apply_op/4`):

    * `"move"`: an absolute target (`parent_id` nil is the root). It runs
      today's `Engram.Folders.rename/5`, which still cascades to every note
      (correct before S5), and acks `%{seq: seq}`. A move to where the folder
      already is acks the current seq and writes nothing. Refusals:
      `"conflict"` (a DIFFERENT live folder holds the target), `"cycle"` (into
      its own subtree; re-checked inside the write transaction under the vault
      seq lock), `"not_found"` (the folder or parent has no live row),
      `"invalid_name"` (not one path segment, or it sanitizes to nothing).
    * `"create"`: find-or-create by `(parent, name)`, like `Rows.ensure/4`
      for every other writer: an existing folder of that name is the same
      folder, never a conflict.

  Both ack `%{folder_id: id, seq: seq}`.

  `op_id` is for logs only (no dedupe table): a replay is safe because both
  ops are absolute.

  Outbound, after a folder op from any surface (plugin, web, MCP; `changed/4`
  is called from `Engram.Folders`), on the vault's `sync:` topic:

    * ONE `folder_changed {folder_id, parent_id, name, seq, deleted,
      device_id}` per folder whose place changed (not its descendants);
      `device_id` is the originating socket's, so the plugin drops its echo.
    * ONE `note_changed {event_type: "upsert", kind: "note", path}` nudge with
      no id, content, hash or seq: plugins 1.36.0 to 1.39.2 answer it with a
      seq catch-up. `path` is the folder's new path and never ends in `.md`
      or `.canvas` (that would route it down the plugin's CRDT branch).

  Today's per-note events keep flowing; these are additive.

  Read side, also only while on: the sync manifest carries `folders: [{id,
  parent_id, name}]` (every live folder, root parent null) and a `folder_id`
  per note (`manifest_rows/1`, `manifest/3`), and the `crdt_create` reply
  carries the note's `folder_id` (`create_reply/1`). Root is null, never a row.
  """

  alias Engram.Crypto
  alias Engram.Folders
  alias Engram.Folders.Rows
  alias Engram.Logger.Metadata
  alias Engram.Notes.PathSanitizer
  alias Engram.Repo
  alias Engram.ServiceConfig
  alias Engram.Sync.Broadcast
  alias Engram.Vaults

  require Logger

  @doc "Whether the wire is on. The only read of the `folder_ops` switch."
  @spec enabled?() :: boolean()
  def enabled?, do: ServiceConfig.get(:folder_ops, false) == true

  @type reply :: {:ok, map()} | {:error, String.t()}

  @doc "Applies one inbound `folder_op` for `device_id`. Call only when `enabled?/0`."
  @spec apply_op(map(), map(), map(), String.t() | nil) :: reply()
  def apply_op(user, vault, payload, device_id) do
    reply =
      case Crypto.ensure_user_dek(user) do
        {:ok, user} -> do_apply(user, vault, payload, device_id)
        {:error, _} -> {:error, "failed"}
      end

    log(vault, payload, reply)
    reply
  end

  defp do_apply(user, vault, %{"op" => "move"} = p, device_id) do
    with {:ok, id} <- cast_id(p["folder_id"]),
         {:ok, parent} <- cast_parent(p["parent_id"]),
         {:ok, name} <- cast_name(p["name"]),
         {:ok, from} <- path_of(user, vault, id),
         {:ok, target} <- target(user, vault, parent, name) do
      if target == from,
        do: {:ok, %{folder_id: id, seq: Vaults.current_seq(user.id, vault.id)}},
        else: move(user, vault, id, from, target, device_id)
    end
  end

  defp do_apply(user, vault, %{"op" => "create"} = p, device_id) do
    with {:ok, parent} <- cast_parent(p["parent_id"]),
         {:ok, name} <- cast_name(p["name"]),
         {:ok, target} <- target(user, vault, parent, name) do
      case Folders.create_markers(user, vault, [target], origin_device_id: device_id) do
        {:ok, %{folders: [_]}} ->
          {id, seq} =
            Repo.with_tenant!(user.id, fn ->
              {Rows.ids_by_path(user, vault.id, [target])[target],
               Vaults.raw_current_seq(vault.id)}
            end)

          {:ok, %{folder_id: id, seq: seq}}

        {:ok, _rejected} ->
          {:error, "invalid_name"}

        {:error, {:rate_limited, _}} ->
          {:error, "rate_limited"}

        {:error, _} ->
          {:error, "failed"}
      end
    end
  end

  defp do_apply(_user, _vault, _payload, _device_id), do: {:error, "bad_frame"}

  # ponytail: resolves the ids to paths before the transaction and moves by
  # path (today's cascade); a move racing in between can make it miss
  # (not_found) or refuse. S5 moves by id under the vault lock.
  defp move(user, vault, id, from, target, device_id) do
    case Folders.rename(user, vault, from, target, origin_device_id: device_id) do
      {:ok, %{notes: 0, attachments: 0}} -> {:error, "not_found"}
      {:ok, %{seq: seq}} when is_integer(seq) -> {:ok, %{folder_id: id, seq: seq}}
      # The switch went off mid-op: no seq was read with the write.
      {:ok, _} -> {:ok, %{folder_id: id, seq: Vaults.current_seq(user.id, vault.id)}}
      {:error, :conflict} -> {:error, "conflict"}
      {:error, :invalid_path} -> {:error, "cycle"}
      {:error, _} -> {:error, "failed"}
    end
  end

  defp path_of(user, vault, id) do
    case Repo.with_tenant!(user.id, fn -> Rows.path_by_id(user, vault.id, id) end) do
      {:ok, path} -> {:ok, path}
      {:error, :not_found} -> {:error, "not_found"}
    end
  end

  defp target(user, vault, parent, name) do
    with {:ok, parent_path} <- if(parent, do: path_of(user, vault, parent), else: {:ok, ""}) do
      # A name the sanitizer changes away from one segment (".." stripped to
      # nothing) is refused rather than silently placed elsewhere.
      case PathSanitizer.sanitize_target(Path.join(parent_path, name)) do
        {:ok, path} when path != "" and path != parent_path -> {:ok, path}
        _ -> {:error, "invalid_name"}
      end
    end
  end

  defp cast_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, "bad_frame"}
    end
  end

  defp cast_id(_), do: {:error, "bad_frame"}

  defp cast_parent(nil), do: {:ok, nil}
  defp cast_parent(id), do: cast_id(id)

  # One segment: a slash would place the folder somewhere the client did not name.
  defp cast_name(name) when is_binary(name) and name != "" do
    if String.contains?(name, ["/", "\\"]), do: {:error, "invalid_name"}, else: {:ok, name}
  end

  defp cast_name(_), do: {:error, "invalid_name"}

  @doc """
  Emits `folder_changed` and the nudge for each of `folders` (their new
  paths) and returns the vault's seq, read in the caller's transaction so it
  is the op's own while the vault seq lock is held. A folder with no live row
  emits nothing. With the switch off: no read, no event, nil.
  """
  @spec changed(map(), map(), [String.t()], String.t() | nil) :: non_neg_integer() | nil
  def changed(user, vault, folders, device_id) do
    # A caller's user struct can predate its DEK (a first write provisions
    # it); without the key no row would be found and nothing emitted.
    with true <- enabled?(),
         {:ok, user} <- Crypto.ensure_user_dek(user) do
      folders = Enum.uniq(folders)
      parents = Map.new(folders, &{&1, parent_path(&1)})

      Repo.with_tenant!(user.id, fn ->
        ids = Rows.ids_by_path(user, vault.id, Enum.uniq(folders ++ Map.values(parents)))
        seq = Vaults.raw_current_seq(vault.id)
        topic = "sync:#{user.id}:#{vault.id}"

        for {f, id} <- Enum.map(folders, &{&1, ids[&1]}), id != nil do
          Broadcast.emit(topic, "folder_changed", %{
            folder_id: id,
            parent_id: ids[parents[f]],
            name: f |> String.split("/") |> List.last(),
            seq: seq,
            deleted: false,
            device_id: device_id
          })

          Broadcast.emit(topic, "note_changed", %{
            event_type: "upsert",
            kind: "note",
            path: nudge_path(f)
          })
        end

        seq
      end)
    else
      _ -> nil
    end
  end

  @doc """
  The manifest's folder rows, read in the manifest's tenant transaction
  (`Rows.live_rows/1`), or nil with the switch off (no read). Cost: one
  O(folders) read here, then O(folders) name decrypts plus an O(notes) map
  lookup in `manifest/3`, next to the manifest's O(notes) path decrypts.
  """
  @spec manifest_rows(map()) :: [map()] | nil
  def manifest_rows(vault), do: if(enabled?(), do: Rows.live_rows(vault.id))

  @doc """
  Adds the folder list and each note's `folder_id` to a rendered manifest,
  given `manifest_rows/1`'s result (nil: the body unchanged). A note's folder
  is found by its decrypted path, not `notes.folder_ref_id`, so the manifest
  keeps its index-only notes read; a note whose folder has no row yet (drift)
  gets `folder_id: nil` and is placed by its path.
  """
  @spec manifest(map(), [map()] | nil, binary()) :: map()
  def manifest(body, nil, _dek), do: body

  def manifest(%{notes: notes} = body, rows, dek) do
    tree = Rows.decrypt_tree(dek, rows)
    id_of = Map.new(tree, &{&1.path, &1.id})

    notes =
      Enum.map(notes, fn n -> Map.put(n, :folder_id, id_of[parent_path(n.path)]) end)

    Map.merge(body, %{
      notes: notes,
      folders: Enum.map(tree, &Map.take(&1, [:id, :parent_id, :name]))
    })
  end

  @doc "The `crdt_create` reply's extra fields: `folder_id` (nil at root) while on."
  @spec create_reply(map()) :: map()
  def create_reply(note),
    do: if(enabled?(), do: %{folder_id: Map.get(note, :folder_ref_id)}, else: %{})

  defp parent_path(path), do: path |> String.split("/") |> Enum.drop(-1) |> Enum.join("/")

  # A trailing slash keeps a folder named like a note off the plugin's CRDT
  # branch (`isCrdtEligiblePath` matches the extension).
  defp nudge_path(path) do
    if path |> String.downcase() |> String.ends_with?([".md", ".canvas"]),
      do: path <> "/",
      else: path
  end

  # op_id is client-supplied: logged only when it is a short string.
  defp log(vault, payload, reply) do
    op_id = payload["op_id"]

    Logger.info(
      "folder_op",
      Metadata.with_category(:info, :sync,
        vault_id: vault.id,
        event_type: if(is_binary(payload["op"]), do: String.slice(payload["op"], 0, 16)),
        event_id: if(is_binary(op_id) and byte_size(op_id) <= 64, do: op_id),
        result:
          case reply do
            {:ok, _} -> "ok"
            {:error, reason} -> reason
          end
      )
    )
  end
end
