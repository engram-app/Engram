defmodule Engram.Workers.ProjectVaultIndex do
  @moduledoc """
  Oban worker: project a vault's `filemeta_v0` index onto the `notes` path
  columns (#1151 step 2).

  This is what keeps REST, search and MCP working against a client-owned CRDT
  index. The server never reads Yjs state to answer "what is this note's path"
  — it reads `notes.path_*`, exactly as `CrdtCheckpoint` projects note CONTENT
  so the same façade keeps working for bodies.

  ## Additive-corrective, and never acting on absence

  Projection walks the INDEX ENTRIES and corrects the row each one names. It
  does not walk the notes and ask whether the index still mentions them.

  That distinction is the whole safety argument. No client writes the index yet
  (Engram-obsidian#362), so in prod every vault's index is empty — and a
  reconcile-by-absence implementation would read an empty index as "this vault
  has no files" and delete the vault. Being additive-corrective is what lets
  this ship dormant instead of armed.

  It follows that projection can never delete a note, and never touches one the
  index does not mention. Deletion stays with the paths that already own it.

  ## Why a worker, not the checkpoint

  `CrdtIndexPersistence.unbind/3` runs inside `terminate/2` against a shutdown
  budget. A projection pass is N renames, and `Notes.rename_note/4` is not
  cheap: it re-encrypts the path, rewrites `path_hmac`, repaths Qdrant points
  and enqueues link rewrites. Doing that in a terminating process during a
  deploy stampede is how you lose the checkpoint AND the projection. The
  checkpoint enqueues this instead; per-vault `unique` collapses a storm into
  one job.

  ## Why it goes through `rename_note/4`

  Writing `path_ciphertext`/`path_nonce`/`path_hmac` directly would be a second
  path writer, and this repo has an exactly-one-rewriter invariant
  (`notes.ex`, `workers/rewrite_note_links.ex`). `rename_note/4` already
  pre-checks the unique `(user, vault, path_hmac)` constraint and answers
  `{:error, :conflict}` rather than crashing, and it carries the Qdrant repath
  and link-rewrite legs with it. Bypassing it would silently drop all of that.
  """
  use Oban.Worker,
    queue: :crdt_checkpoint,
    max_attempts: 3,
    unique: [keys: [:vault_id], states: :incomplete]

  alias Engram.{Accounts, Crypto, Notes, Repo}
  alias Engram.Crypto.RotationGate
  alias Engram.Logger.Metadata
  alias Engram.Notes.{CrdtIndexDoc, VaultIndexState}

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "vault_id" => vault_id}}) do
    case Accounts.get_user(user_id) do
      nil ->
        # Purged mid-flight. Expected, not exceptional (#954).
        :ok

      user ->
        # This decrypts the index snapshot, so it must not run mid-rotation
        # against a key the sweep is moving underneath it (#1341).
        case RotationGate.check_user(user) do
          {:error, :rotation_in_progress} ->
            {:snooze, 30}

          _ ->
            project(user, vault_id)
        end
    end
  end

  defp project(user, vault_id) do
    case load_entries(user, vault_id) do
      {:ok, entries} ->
        vault = %{id: vault_id}
        Enum.each(entries, &apply_entry(user, vault, vault_id, &1))
        :ok

      :none ->
        # No snapshot yet — a vault whose index room has never checkpointed.
        :ok

      {:error, reason} ->
        Logger.error(
          "vault index projection could not read the snapshot: #{inspect(reason)}",
          Metadata.with_category(:error, :sync, user_id: user.id, vault_id: vault_id)
        )

        # Do NOT retry into a decrypt failure — it will not fix itself, and the
        # rows are untouched either way.
        :ok
    end
  end

  defp load_entries(user, vault_id) do
    {:ok, row} =
      Repo.with_tenant(user.id, fn -> Repo.get(VaultIndexState, vault_id) end)

    case row do
      nil ->
        :none

      row ->
        with {:ok, snapshot} <- Crypto.decrypt_index_state(row, user) do
          doc = Yex.Doc.new()
          :ok = Yex.apply_update(doc, snapshot)

          {:ok,
           doc
           |> Yex.Doc.get_map(CrdtIndexDoc.map_name())
           |> Yex.Map.to_map()}
        end
    end
  end

  # One entry at a time, and one entry's failure never stops the next: a single
  # collision or a stale id would otherwise strand every entry behind it.
  defp apply_entry(user, vault, vault_id, {path, %{"note_id" => note_id}})
       when is_binary(path) and is_binary(note_id) do
    case Notes.get_note_by_id(user, vault, note_id) do
      # No `path == current` short-circuit: rename_note/4 already answers
      # {:no_change, note} for a same-path rename without touching the row, so a
      # guard here would be unreachable-by-behaviour — a mutation removing it
      # changed nothing observable, which is the definition of code a test
      # cannot justify.
      #
      # Read `note.path` rather than destructuring it in the pattern:
      # NoPlaintextArgsTest lints worker source line-by-line for a bare `path:`
      # key, and cannot tell a Note pattern-match from an args map. The lint is
      # right to be blunt — Oban args are JSONB and outlive the job — so this
      # sidesteps it honestly instead of reaching for its `noqa` escape hatch.
      {:ok, note} when is_binary(note.path) ->
        rename(user, vault, note.path, path, note_id, vault_id)

      _ ->
        # The index names a note this vault does not have. Not ours to invent:
        # creating one here would make projection a WRITER of identity, which
        # is the client's job.
        :ok
    end
  end

  defp apply_entry(user, _vault, vault_id, {path, other}) do
    Logger.warning(
      "vault index projection skipped a malformed entry at #{inspect(path)}: #{inspect(other)}",
      Metadata.with_category(:warning, :sync, user_id: user.id, vault_id: vault_id)
    )

    :ok
  end

  defp rename(user, vault, current, path, note_id, vault_id) do
    case Notes.rename_note(user, vault, current, path) do
      {:ok, _note} ->
        :ok

      {:error, reason} ->
        # :conflict means the target path is already held by a DIFFERENT note.
        # The index and the rows disagree, and projection is not the layer that
        # resolves that — the client owns identity. Leave both rows alone and
        # say so; silently dropping it would make the disagreement invisible.
        Logger.warning(
          "vault index projection could not move #{note_id}: #{inspect(reason)}",
          Metadata.with_category(:warning, :sync,
            user_id: user.id,
            vault_id: vault_id,
            note_id: note_id
          )
        )

        :ok
    end
  end
end
