defmodule Engram.DataMigrations.NoteMeta do
  @moduledoc """
  Every live note's stored title, tags and outgoing links checked under the
  current derivation rules (`Engram.Notes.Helpers.meta_version/0`), so a rule
  change (#2564: the shared frontmatter fence) reaches notes nobody edits,
  with no operator step. The name carries the version: a bump is a new,
  not-done migration.

  The pattern is `KeyAliases` + `HealKeyAliases` (a per-note stamp; an
  unchanged note is only stamped, a changed one is rewritten and re-read by
  `RebuildStaleNote`), walked the current way: `IdWindows.heal_pass/4` over
  `notes` by primary key, so no statement reads outside its window and no
  index is needed on the stamp.

  Per stale note, in its owner's tenant: the row and its tail in one
  statement, the authoritative text (`Notes.authoritative_content/3`, not the
  facade, see `docs/context/worker-reads-stale-content-facade.md`), title and
  tags from `Helpers.extract_title_and_tags/2`, links from
  `Links.Parser.extract/1`. One short transaction per note: a compare-and-set
  on the row's `version` and `content_hash` writes the stamp (and the title
  and tags only when they moved), then the links are synced (written only
  when they differ). A note whose title moved is re-read by
  `RebuildStaleNote` (reuses every unchanged vector; only a chunk whose
  context changed re-embeds). Nothing else re-embeds.

  Writers do not stamp: they derive under the current rules already, so an
  unstamped new note needs no work. `:done` is one walk that REWROTE nothing
  and left nothing; a stamp alone is not a fix, so notes created during the
  walk cannot hold it open. Users mid DEK rotation, lost compare-and-sets
  and notes whose text does not decrypt are left, and keep it open (the
  ledger's rule: a closed ledger never hides an unfixed row).

  Accepted: a previous-release node in a rolling deploy can rewrite a
  stamped note under the old rules; that note heals on its next edit, as
  every note did before this migration.

  Kill switch: the `note_meta_backfill` service override, default OFF: it is
  turned on after the deploy has been validated on staging. A legacy row is
  handed over by `Engram.Crypto.AadRebind.rebind_note/2`, which clears its
  stamp and reopens this ledger.
  """
  @behaviour Engram.DataMigration

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Backfill.IdWindows
  alias Engram.Crypto
  alias Engram.Crypto.RotationGate
  alias Engram.DataMigrations.IndexVersions
  alias Engram.Links
  alias Engram.Links.Parser
  alias Engram.Logger.DecryptFailure
  alias Engram.Notes
  alias Engram.Notes.{CrdtUpdateLog, Helpers, NameIndex, Note}
  alias Engram.Repo
  alias Engram.Workers.RebuildStaleNote

  # Every stale note costs a CRDT decode and four short statements, so a
  # window is smaller than the size ledgers'. Rewrites per pass are capped;
  # stamps are bounded by the runner's 240 s pass budget.
  @batch 200
  @max_fixed 2_000

  @impl true
  def name, do: "note_meta:#{Helpers.meta_version()}"

  @impl true
  def version, do: 1

  @impl true
  def enabled?, do: Engram.ServiceConfig.get(:note_meta_backfill, false) == true

  @doc "True once every note was checked under the current rules."
  @spec done?() :: boolean()
  def done?, do: Engram.DataMigrations.done?(name(), version())

  @impl true
  def run_pass, do: run_pass([])

  @doc false
  def run_pass(opts) do
    IdWindows.heal_pass(name(), Note, &heal_window/2,
      batch_size: Keyword.get(opts, :batch, @batch),
      max_fixed: Keyword.get(opts, :max_fixed, @max_fixed),
      fun_in_tenant: false
    )
  end

  @doc """
  Live notes among `ids` not yet checked under the current rules. A stamp
  from a newer release counts as current (a rollback re-checks nothing).

  AAD-bound rows only: the rewrite encrypts title and tags bound to the row,
  as every writer does. A legacy (pre-bind) row is the rebind's work first,
  as for `CrdtCheckpoint` (`:legacy_row_needs_rebind`), so it is not this
  migration's and cannot hold it open.
  """
  @spec stale([Ecto.UUID.t()]) :: Ecto.Query.t()
  def stale(ids) do
    version = Helpers.meta_version()

    ids
    |> IndexVersions.live_notes()
    |> where([n], is_nil(n.meta_version) or n.meta_version < ^version)
    |> where([n], n.dek_version == ^Crypto.row_version_aad_bound())
  end

  @doc """
  Heals the stale notes among `ids`. Returns `{rewritten, left?}`.
  Public for the tenant-scoping tests.
  """
  @spec heal_window([Ecto.UUID.t()], IdWindows.ctx()) :: {non_neg_integer(), boolean()}
  def heal_window(ids, ctx) do
    ids
    |> read_stale(ctx)
    |> Enum.group_by(fn {_id, user_id} -> user_id end, fn {id, _} -> id end)
    |> Enum.reduce({0, false}, fn {user_id, note_ids}, {fixed, left} ->
      {f, l} = heal_user(user_id, note_ids)
      {fixed + f, left or l}
    end)
  end

  # The fleet walk reads on the maintenance pool; a per-user walk (no pool)
  # inside that user's tenant, since FORCE RLS would read zero rows outside it.
  defp read_stale(ids, %{repo: repo, user_id: nil}),
    do: repo.all(select(stale(ids), [n], {n.id, n.user_id}))

  defp read_stale(ids, %{user_id: user_id}),
    do: Repo.with_tenant!(user_id, fn -> Repo.all(select(stale(ids), [n], {n.id, n.user_id})) end)

  defp heal_user(user_id, note_ids) do
    with %User{} = user <- Repo.get(User, user_id),
         :ok <- RotationGate.check_user(user) do
      Enum.reduce(note_ids, {0, false}, fn id, {fixed, left} ->
        case heal_note(user, id) do
          :rewritten -> {fixed + 1, left}
          :stamped -> {fixed, left}
          :left -> {fixed, true}
        end
      end)
    else
      # A deleted user's notes cascade away; a rotation re-keys them.
      nil -> {0, false}
      {:error, :rotation_in_progress} -> {0, true}
    end
  end

  defp heal_note(user, id) do
    case Notes.fetch_note_with_tail_for_worker(id, user.id) do
      {:ok, note, tail} -> derive(user, note, tail)
      # Deleted since the window read.
      {:discard, _reason} -> :stamped
    end
  end

  defp derive(user, note, tail) do
    with {:ok, dec} <- Crypto.maybe_decrypt_note_fields(note, user),
         {:ok, text} <- Notes.authoritative_content(user, dec, tail) do
      {title, tags} = Helpers.extract_title_and_tags(text, dec.path)
      meta? = (title || "") != (dec.title || "") or tags != (dec.tags || [])
      write(user, dec, tail, meta? && {title, tags}, Parser.extract(text))
    else
      {:error, reason} ->
        DecryptFailure.log("note_meta_decrypt_failed", reason, user_id: user.id, note_id: note.id)
        :left
    end
  end

  # One tenant transaction: the stamp (plus title and tags when they moved)
  # under a compare-and-set, then the links and a moved title's re-index job,
  # so a concurrent write either lands first (and we leave the note) or waits
  # for us on the row lock, and a stamped title always has its re-index.
  @doc false
  # Public for the race tests: they change the note between the read and here.
  def write(user, note, tail, meta, parsed) do
    result =
      Repo.with_tenant!(user.id, fn ->
        with false <- tail_grew?(note, tail),
             {1, _} <-
               Repo.update_all(cas(note),
                 set: [meta_version: Helpers.meta_version()] ++ meta_cols(user, note, meta)
               ) do
          {links?, _} = Links.sync_links(user, %{id: note.vault_id}, note.id, parsed)

          if title_moved?(note, meta),
            do: :ok = RebuildStaleNote.enqueue_reread(note.id, note.user_id)

          if meta || links?, do: :rewritten, else: :stamped
        else
          _ -> :left
        end
      end)

    _ =
      if result == :rewritten and title_moved?(note, meta),
        do: NameIndex.announce(note.vault_id, note.id, note.path, elem(meta, 0))

    result
  end

  # A CRDT write that has not checkpointed (a live edit, a link rewrite's
  # roomless persist) appends to the tail and moves neither `version` nor
  # `content_hash`, so the compare-and-set cannot see it: a tail row we did not
  # read means our text is stale, and writing its links would undo the
  # rewrite's. The note is left for the next pass.
  defp tail_grew?(note, tail) do
    read = Enum.map(tail, & &1.id)

    Repo.exists?(
      from(l in CrdtUpdateLog, where: l.note_id == ^note.id and l.id not in ^read, select: 1)
    )
  end

  defp meta_cols(_user, _note, false), do: []

  defp meta_cols(user, note, {title, tags}) do
    {:ok, enc} = Crypto.encrypt_note_fields(%{title: title}, user, note.id)

    tag_cols =
      Notes.inject_phase_b_fields_pub(%{}, user, note.id, note.path, note.folder, tags, note)

    Map.to_list(Map.merge(Map.take(enc, [:title_ciphertext, :title_nonce]), tag_cols))
  end

  # The stored title is what search's name leg and the editor's link index
  # read: a moved one re-indexes (vectors reused, only a changed chunk context
  # re-embeds) and is told to the name index. Tags live only in Postgres.
  defp title_moved?(_note, false), do: false
  defp title_moved?(note, {title, _tags}), do: (title || "") != (note.title || "")

  # A write in between wins: it derived under the current rules itself. A
  # note trashed in between is left alone (a trash moves neither `version`
  # nor `content_hash`).
  defp cas(%Note{content_hash: nil} = note),
    do: where(unchanged(note), [n], is_nil(n.content_hash))

  defp cas(note), do: where(unchanged(note), [n], n.content_hash == ^note.content_hash)

  defp unchanged(note),
    do:
      from(n in Note,
        where: n.id == ^note.id and n.version == ^note.version and is_nil(n.deleted_at)
      )
end
