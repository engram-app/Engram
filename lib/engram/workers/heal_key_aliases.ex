defmodule Engram.Workers.HealKeyAliases do
  @moduledoc """
  Re-reads one user's notes under the current key alias table
  (`Engram.Notes.KeyAliases`) once the table's version moved, run by the
  `Engram.DataMigrations.KeyAliases` migration. CPU only.

  For each content-current note stamped with another version (NULL: never
  read under a stamp), it compares what the frontmatter gives TODAY with
  what is indexed: the named-field `note_attrs` rows and the row's `type`
  blind index and `description`. A note indexed before the v5 layout has no
  rows, so one with named fields reads as changed and is re-indexed into the
  v5 layout. Unchanged: the note is just stamped, its index untouched. Changed: the row's OKF fields are rewritten from the
  content and a `RebuildStaleNote` (`key_aliases: true`) re-indexes it,
  paced by the maintenance token bucket: every unchanged vector is reused
  (0 Voyage) and the payload refreshed; only a changed chunk-0 lead line
  (a `type`/`description` alias) re-embeds. That pass stamps the version.

  One chain per user, resumed at an id cursor. Content is never logged.
  """
  # On the hourly-backfill lane like `BackfillLinkKeys`: `maintenance` is
  # for cron workers only (`ObanQueueConfigTest`).
  use Oban.Worker,
    queue: :crdt_backfill,
    priority: 3,
    max_attempts: 5,
    unique: [keys: [:user_id], period: :infinity, states: [:available, :scheduled, :retryable]]

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Backfill.TenantScan
  alias Engram.Crypto
  alias Engram.Crypto.RotationGate
  alias Engram.DataMigrations.IndexVersions
  alias Engram.Notes
  alias Engram.Notes.{FlatFields, Frontmatter, FrontmatterKeys, KeyAliases, NoteAttr, OkfFields}
  alias Engram.Repo
  alias Engram.Workers.{EmbedNote, RebuildStaleNote}

  @batch 200

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id} = args}) do
    # A heal re-encrypts the OKF fields: under a DEK a rotation is replacing
    # they would not decrypt afterwards, so it waits the rotation out.
    with %User{} = user <- Repo.get(User, user_id),
         :ok <- RotationGate.check_user(user),
         {:ok, fk} <- Crypto.dek_filter_key(user) do
      notes = Repo.with_tenant!(user_id, fn -> Repo.all(page(user_id, args["after"])) end)
      Enum.each(notes, &heal(&1, user, fk))

      continue(user_id, notes)
    else
      nil -> :ok
      {:error, :rotation_in_progress} -> {:snooze, 60}
      {:error, _} = err -> err
    end
  end

  # A full page: the successor resumes after its last id.
  defp continue(user_id, notes) when length(notes) == @batch do
    {:ok, _} = Oban.insert(new(%{"user_id" => user_id, "after" => List.last(notes).id}))
    :ok
  end

  defp continue(_user_id, _notes), do: :ok

  @doc "Enqueues a chain for every user with a note read under another table. Returns how many."
  @spec enqueue_missing() :: non_neg_integer()
  def enqueue_missing do
    user_ids =
      TenantScan.flat_map_users(fn uid ->
        if Repo.exists?(where(stale(), [n], n.user_id == ^uid)), do: [uid], else: []
      end)

    executing = TenantScan.executing_user_ids(__MODULE__)

    # One insert per user: Oban's Basic engine ignores `unique` in insert_all.
    for uid <- user_ids,
        not MapSet.member?(executing, uid),
        do: {:ok, _} = Oban.insert(new(%{"user_id" => uid}))

    length(user_ids)
  end

  @doc "Content-current live notes not yet read under `KeyAliases.version/0`."
  def stale do
    version = KeyAliases.version()

    where(
      IndexVersions.content_current_notes(),
      [n],
      is_nil(n.key_alias_version) or n.key_alias_version != ^version
    )
  end

  defp page(user_id, after_id) do
    q = stale() |> where([n], n.user_id == ^user_id) |> order_by([n], n.id) |> limit(@batch)
    if after_id, do: where(q, [n], n.id > ^after_id), else: q
  end

  defp heal(note, user, fk) do
    with {:ok, note} <- Crypto.maybe_decrypt_note_fields(note, user) do
      if moved?(note, fk), do: reindex(note, user), else: stamp(note)
    end
  end

  # What today's alias table reads from the frontmatter, against what the
  # note's index holds.
  defp moved?(note, fk) do
    block = with {block, _body} <- Frontmatter.split(note.content || ""), do: block
    okf = OkfFields.from_parse(block && Frontmatter.parse(block))
    type_hmac = okf.type && Crypto.hmac_field(fk, OkfFields.normalize_type(okf.type))

    expected =
      note.content
      |> FlatFields.extract(fk)
      |> FlatFields.attr_rows(%{note | type_hmac: nil, tags_hmac: nil})
      |> Enum.map(&{&1.key_id, &1.ord, &1.h, &1.n, &1.d})
      |> Enum.sort()

    type_hmac != note.type_hmac or okf.description != note.description or
      expected != named_rows(note)
  end

  # The named fields' rows (type and tags come from the note row).
  defp named_rows(note) do
    skip = [FrontmatterKeys.named_id(:type), FrontmatterKeys.named_id(:tags)]

    Repo.with_tenant!(note.user_id, fn ->
      from(a in NoteAttr,
        where:
          a.note_id == ^note.id and a.key_id < ^FrontmatterKeys.first_user_id() and
            a.key_id not in ^skip,
        select: {a.key_id, a.ord, a.h, a.n, a.d}
      )
      |> Repo.all()
      |> Enum.sort()
    end)
  end

  defp reindex(note, user) do
    okf = Notes.inject_frontmatter_fields_pub(%{}, user, note.id, note.content)

    Repo.with_tenant!(note.user_id, fn ->
      Repo.update_all(cas(note), set: Map.to_list(okf))
    end)

    # The lowest priority, as the reconcile sweep queues an upgrade: never
    # ahead of the v5 pass's jobs (priority 0 would jump all of them).
    args = %{note_id: note.id, user_id: note.user_id, upgrade: true, key_aliases: true}
    {:ok, _} = Oban.insert(RebuildStaleNote.new(args, priority: EmbedNote.backfill_priority()))
  end

  defp stamp(note) do
    Repo.with_tenant!(note.user_id, fn ->
      Repo.update_all(cas(note), set: [key_alias_version: KeyAliases.version()])
    end)
  end

  # An edit in between wins: its own index reads the current table.
  defp cas(note),
    do: from(n in Notes.Note, where: n.id == ^note.id and n.content_hash == ^note.content_hash)
end
