defmodule EngramWeb.VaultTreeController do
  @moduledoc """
  One read for the web file tree.

  The tree needs every folder, note and attachment in the vault at once.
  `/api/folders/list?folder=` was built for the plugin, which walks one
  folder at a time, so the SPA was firing one request per folder — 20-33
  requests moving 39.5 KB, serialized 6-at-a-time by the HTTP/1.1
  connection limit, up to 5.6s of pure queueing before the last one was
  even sent. This is that same data in one response.

  Payload is deliberately minimal: `noteToTreeItem` derives title and
  extension from `path`, so `title`, `tags`, `version`, `mtime`,
  `content_hash` and `crdt_head` are all omitted. Reusing the sync
  manifest was rejected for exactly that reason — it carries ~128 bytes
  per note of hashes the tree never reads (~1.3 MB at 10k notes).
  """
  use EngramWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Engram.Attachments
  alias Engram.Crypto
  alias Engram.Logger.Metadata
  alias Engram.Notes
  alias Engram.Repo
  alias Engram.Vaults
  alias EngramWeb.Schemas

  require Logger

  operation(:show,
    operation_id: "vault-tree",
    summary: "Get the whole vault tree in one read",
    tags: ["Vaults"],
    description: "Every folder, note and attachment the file tree renders, in one response.",
    responses: [ok: {"Vault tree", "application/json", Schemas.VaultTreeResponse}]
  )

  def show(conn, _params) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    # One with_tenant block for every DB read this endpoint needs (was 5:
    # current_seq + notes + folder counts + folder markers + attachments,
    # each its own transaction). Decrypt happens entirely below, OUTSIDE
    # this block — holding a DB connection across that CPU-bound work is
    # the shape behind the 2026-07-09 CRDT pool-exhaustion incident (#1211).
    {:ok, raw} =
      Repo.with_tenant(user.id, fn ->
        %{
          seq: Vaults.raw_current_seq(vault.id),
          tree_rows: Notes.raw_tree_rows(user, vault),
          attachment_rows: Attachments.raw_tree_rows(user, vault)
        }
      end)

    case Crypto.get_dek(user) do
      {:ok, dek} ->
        render_tree(conn, raw, dek, user)

      {:error, :no_dek} ->
        # Brand-new user, zero writes yet: every upsert provisions a DEK, so
        # no DEK means nothing encrypted exists to render. raw.tree_rows /
        # raw.attachment_rows are already known empty in this case — no
        # extra query cost, just skipped decrypt.
        json(conn, empty_tree(raw.seq))

      {:error, reason} ->
        # Anything else (:unrecognised_blob, a propagated unwrap_dek/2
        # failure) is a real crypto fault, not "no notes yet" — rendering an
        # empty tree here would tell the user their vault is gone when it
        # isn't. Log with enough to diagnose and let it fail loudly (500)
        # instead of disguising it as an empty vault.
        Logger.error(
          "vault tree: DEK unavailable, refusing to render",
          Metadata.with_category(:error, :crypto,
            user_id: user.id,
            vault_id: vault.id,
            reason: Crypto.format_dek_error(reason)
          )
        )

        raise "vault tree: DEK unavailable (#{Crypto.format_dek_error(reason)})"
    end
  end

  defp empty_tree(current_seq) do
    %{folders: [], notes: [], attachments: [], change_seq: current_seq}
  end

  defp render_tree(conn, raw, dek, user) do
    %{notes: notes, folders: folders} = Notes.build_tree_payload(raw.tree_rows, dek)
    attachments = Attachments.decrypt_tree_rows(raw.attachment_rows, user)

    json(conn, %{
      folders: folders,
      notes: Enum.sort_by(notes, & &1.path),
      # decrypt_tree_rows/2 carries content_hash for the sync-facing listing;
      # the tree never reads it, and the whole point of this endpoint is that
      # it does not ship per-file hashes (see the moduledoc). Dropped here so
      # the attachment half keeps the promise the notes half already makes.
      attachments:
        attachments |> Enum.sort_by(& &1.path) |> Enum.map(&Map.delete(&1, :content_hash)),
      change_seq: raw.seq
    })
  end
end
