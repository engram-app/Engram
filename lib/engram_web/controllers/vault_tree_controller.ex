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
    current = Engram.Vaults.current_seq(user.id, vault.id)

    case Crypto.get_dek(user) do
      {:ok, _dek} ->
        render_tree(conn, user, vault, current)

      {:error, :no_dek} ->
        # Brand-new user, zero writes yet: every upsert provisions a DEK, so
        # no DEK means nothing encrypted exists to render.
        json(conn, empty_tree(current))

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

  defp render_tree(conn, user, vault, current_seq) do
    {:ok, notes} = Notes.list_tree_notes(user, vault)
    {:ok, attachments} = Attachments.list_attachments(user, vault)

    json(conn, %{
      folders: Notes.folders_payload(user, vault),
      notes: Enum.sort_by(notes, & &1.path),
      attachments: Enum.sort_by(attachments, & &1.path),
      change_seq: current_seq
    })
  end
end
