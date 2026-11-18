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
  alias Engram.Folders.Rows
  alias Engram.Logger.Metadata
  alias Engram.Notes
  alias Engram.Notes.Location
  alias Engram.Repo
  alias Engram.Vaults
  alias EngramWeb.ETag
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

    # Computed once, before the transaction opens — no DB access (a pure
    # struct decrypt), so nothing is lost by resolving it up front instead
    # of inside with_tenant. Branching on the precomputed value below (never
    # calling Crypto.get_dek/1 again) means a DEK failure doesn't also pay
    # for the note/folder/attachment queries it can't use.
    dek_result = Crypto.get_dek(user)
    # Read once: the ETag and the payload's shape must agree.
    names? = Location.on?()

    # One with_tenant block for every DB read this endpoint needs (was 5:
    # current_seq + notes + folder counts + folder markers + attachments,
    # each its own transaction). Decrypt happens entirely below, OUTSIDE
    # this block — holding a DB connection across that CPU-bound work is
    # the shape behind the 2026-07-09 CRDT pool-exhaustion incident (#1211).
    # One snapshot (`Repo.with_tenant_snapshot!/2`): the seq, the etag and
    # every row set below agree, so a folder count cannot disagree with the
    # rows it is shown beside.
    raw =
      Repo.with_tenant_snapshot!(user.id, fn ->
        seq = Vaults.raw_current_seq(vault.id)
        etag = etag(user, vault, seq, names?)

        cond do
          # Nothing in the tree moved since the client's copy: answer from
          # the seq read alone, before the note/folder/attachment queries.
          # A real DEK fault still 500s below rather than hiding behind a 304.
          dek_usable?(dek_result) and ETag.matches?(conn, etag) ->
            %{seq: seq, etag: etag, not_modified: true}

          match?({:ok, _}, dek_result) ->
            %{
              seq: seq,
              etag: etag,
              note_rows: Notes.raw_tree_note_rows(user, vault),
              folder_counts: Notes.raw_folder_counts_at(user, vault, seq),
              explicit_folder_rows: Notes.raw_explicit_folder_rows(user, vault),
              attachment_rows: Attachments.raw_tree_rows(user, vault)
            }
            |> with_folder_rows(user, vault, names?)

          true ->
            # No usable DEK: nothing decryptable exists to fetch (:no_dek) or
            # the caller is about to 500 without using rows anyway (any other
            # error) — skip the note/folder/attachment queries entirely.
            %{seq: seq, etag: etag}
        end
      end)

    conn =
      conn
      |> put_resp_header("etag", raw.etag)
      # Per-user, per-vault body: a browser may keep it but must revalidate
      # every time, and no shared cache may store it. Not on the Cloudflare
      # Cache Rule (docs/context/edge-cache-request-varying-headers.md).
      |> put_resp_header("cache-control", "private, no-cache")

    case {raw, dek_result} do
      {%{not_modified: true}, _} ->
        send_resp(conn, 304, "")

      {_, {:ok, dek}} ->
        render_tree(conn, raw, dek, user)

      {_, {:error, :no_dek}} ->
        # Brand-new user, zero writes yet: every upsert provisions a DEK, so
        # no DEK means nothing encrypted exists to render.
        json(conn, empty_tree(raw.seq))

      {_, {:error, reason}} ->
        # Anything else (:unrecognised_blob, a propagated unwrap_dek/2
        # failure) is a real crypto fault, not "no notes yet" — rendering an
        # empty tree here would tell the user their vault is gone when it
        # isn't. Log with enough to diagnose and let it fail loudly (500)
        # instead of disguising it as an empty vault. A transient load
        # failure (a stalled KMS call) raises as a retryable 503 instead.
        Logger.error(
          "vault tree: DEK unavailable, refusing to render",
          Metadata.with_category(:error, :crypto,
            user_id: user.id,
            vault_id: vault.id,
            reason: Crypto.format_dek_error(reason)
          )
        )

        raise Crypto.DekUnavailableError, reason
    end
  end

  # Every write to a note, folder marker or attachment row takes a fresh seq
  # from vaults.change_seq (Vaults.next_seq!/1), the same invariant the sync
  # manifest's `since_seq` short-circuit relies on, so the seq alone tracks
  # the payload. Writes that skip it (DEK rotation, AAD rebind) re-encrypt
  # the same plaintext and change nothing the tree shows. user and vault ids
  # keep a tag unusable against another tree (two fresh vaults share seq 0);
  # the release version (and the name-reads switch) retires every tag when
  # the payload shape changes.
  defp etag(user, vault, seq, names?) do
    vsn = Application.spec(:engram, :vsn)
    # The name reads change the payload's shape (`folder_tree`, `folder_id`),
    # so flipping their switch retires every tag too.
    names = if names?, do: "n", else: "p"
    hash = :crypto.hash(:sha256, "#{user.id}:#{vault.id}:#{seq}:#{vsn}:#{names}")
    ~s(") <> Base.url_encode64(binary_part(hash, 0, 16), padding: false) <> ~s(")
  end

  # The folder rows (O(1) folder rename plan, #2523) with the S3 name reads
  # on, read with the moved-folder probe folded in, and the moved notes'
  # locations (nil unless a folder was moved without a cascade, never
  # before S5). Inside the tree's snapshot.
  defp with_folder_rows(raw, user, vault, names?) do
    rows = if names?, do: Rows.live_rows(vault.id, Location.moved_column(vault.id))

    # Names off still serves a moved vault's notes where they are
    # (`Location`'s latch): one probe instead of the rows' moved column.
    moves =
      if rows,
        do: Location.listing_moves(user, vault, rows),
        else: Location.vault_moves(user, vault)

    Map.merge(raw, %{folder_rows: rows, moves: moves})
  end

  defp dek_usable?({:ok, _}), do: true
  defp dek_usable?({:error, :no_dek}), do: true
  defp dek_usable?(_), do: false

  defp empty_tree(current_seq) do
    %{folders: [], notes: [], attachments: [], change_seq: current_seq}
  end

  defp render_tree(conn, raw, dek, user) do
    moved = Location.listing_paths(user, raw.moves)

    notes =
      raw.note_rows
      |> Notes.decrypt_tree_note_rows(dek)
      |> Enum.map(&%{&1 | path: Map.get(moved, &1.id, &1.path)})

    # Additive: each note's `folder_id` and `name`, and `folder_tree:
    # [%{id, parent_id, name}]` (folder rows; `folders` keeps its counts
    # shape for the SPA). Both absent with names off.
    {notes, extra} =
      case raw.folder_rows do
        nil ->
          {notes, %{}}

        rows ->
          {notes, tree} = Location.place(notes, rows, dek)
          {notes, %{folder_tree: tree}}
      end

    folder_counts =
      Notes.folder_counts_at(conn.assigns.current_vault, raw.seq, raw.folder_counts, dek)

    explicit = Notes.decrypt_explicit_folder_rows(raw.explicit_folder_rows, dek)
    folders = Notes.combine_folders_payload(folder_counts, explicit)
    attachments = Attachments.decrypt_tree_rows(raw.attachment_rows, user)

    json(
      conn,
      Map.merge(extra, %{
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
    )
  end
end
