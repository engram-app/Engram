defmodule Engram.Notes.LineageAudit do
  @moduledoc """
  Read-only detector for notes whose CRDT body holds RIVAL lineages.

  A root insert is a body item written into an EMPTY text (no origin, no right
  origin). Yjs keeps deleted neighbours as origins, so a healthy note has
  exactly one root struct, however it was edited, even cleared and retyped. A
  second one means a writer seeded the body into a doc it had never synced,
  and Yjs unioned the copies. Each finding carries every root lineage, wholly
  deleted ones included, as `{live, total}` UTF-16 lengths:

    * **rival**: two or more LIVE roots. The body is doubled now.
    * **suspect**: at most one live root, but two or more roots. Either the
      user deleted the duplicate by hand (healthy text), or a fresh device
      seeded a note that had been cleared and retyped (the original root is
      dead, the rival is live, the body is doubled, e.g. "new textnew text").
      Live roots alone cannot tell these apart. Triage reads the text for
      duplication; the audit never puts text in its output.
    * healthy otherwise (at most one root, live or not).

  Known causes of a rival lineage:

    * the plugin's fresh-device seed (plugin #619, #846, #476);
    * the web app's `flattenIfBloated` (removed in this change);
    * the server checkpoint flatten (removed in #2118, before 0.60.2).

  Known triage noise (a finding, but not a bug):

    * two devices typing into a genuinely empty new note before either syncs;
    * weak links: engram_native's yrs is built without the "weak" feature, so a
      doc holding one does not decode and is reported `:undecodable`.

  From prod (Mix tasks are not in the release):

      bin/engram rpc 'Engram.Notes.LineageAudit.run() |> IO.inspect(limit: :infinity)'
      bin/engram rpc 'Engram.Notes.LineageAudit.run(user_id: "...") |> IO.inspect()'
      bin/engram rpc 'Engram.Notes.LineageAudit.run(limit: 5000, after_id: "<last_id>") |> IO.inspect()'

  Output and logs are ids, counts and reason atoms only: no content, titles or
  paths. Only the CRDT state (snapshot + update-log tail) is decrypted, never
  the content, title or path columns. Writes nothing, starts no room or job.
  One note at a time, ordered by id; `last_id` (in the result and on every
  progress line, each `progress_every:` notes, default 1000) resumes a
  cut-short run. A note whose scan raises is reported unreadable (`:error`)
  and the run goes on.
  """
  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Crypto
  alias Engram.Logger.Metadata
  alias Engram.Native
  alias Engram.Notes.{CrdtBridge, CrdtPersistence, CrdtUpdateLog, Note}
  alias Engram.Repo
  alias Engram.Vaults.Vault

  require Logger

  @progress_every 1_000

  @type reason :: :decrypt | :undecodable | :owner_missing | :not_found | :error
  @type finding :: %{
          note_id: String.t(),
          live_root_count: non_neg_integer(),
          root_count: non_neg_integer(),
          root_client_count: non_neg_integer(),
          lineage_lengths: [{live :: non_neg_integer(), total :: non_neg_integer()}]
        }
  @type result :: %{
          scanned: non_neg_integer(),
          rivals: [finding],
          suspects: [finding],
          unreadable: [%{note_id: String.t(), reason: reason}],
          unreadable_count: non_neg_integer(),
          last_id: String.t() | nil
        }

  @doc """
  Scan every live note with CRDT state (snapshot or update-log rows), or one
  user's (`user_id:`). `limit:` caps the notes scanned and `after_id:` starts
  past an id (notes go in id order), so `last_id` of one run resumes the next.
  `progress_every:` sets how often a progress line is logged (default 1000).
  `scan:` replaces `scan_note/3` (tests only: a scan that raises).

  `{:error, :no_maintenance_repo}` where RLS would silently hide every row, and
  `{:error, :scanned_nothing}` for a whole-fleet run (no `user_id:`, no
  `after_id:`) that found no note, the other shape of a silently hidden table.
  """
  @spec run(keyword()) :: {:ok, result} | {:error, :no_maintenance_repo | :scanned_nothing}
  def run(opts \\ []) do
    if Repo.maintenance() == Repo and Engram.Repo.TenancyGuard.enforced?() do
      {:error, :no_maintenance_repo}
    else
      acc = %{
        scanned: 0,
        rivals: [],
        suspects: [],
        unreadable: [],
        unreadable_count: 0,
        last_id: nil
      }

      every = Keyword.get(opts, :progress_every, @progress_every)
      scan = Keyword.get(opts, :scan, &scan_note/3)
      result = opts |> targets() |> Enum.reduce(acc, &tally(&1, &2, scan, every))

      if result.scanned == 0 and is_nil(opts[:user_id]) and is_nil(opts[:after_id]) do
        {:error, :scanned_nothing}
      else
        {:ok,
         %{
           result
           | rivals: Enum.reverse(result.rivals),
             suspects: Enum.reverse(result.suspects),
             unreadable: Enum.reverse(result.unreadable)
         }}
      end
    end
  end

  @doc "One note. `{:ok, finding}` or `{:error, reason}`."
  @spec scan_note(User.t() | nil, Vault.t() | nil, String.t()) ::
          {:ok, finding} | {:error, reason}
  def scan_note(user, vault, _note_id) when is_nil(user) or is_nil(vault),
    do: {:error, :owner_missing}

  def scan_note(user, vault, note_id) do
    with {:ok, update} <- crdt_state(user, vault, note_id),
         {:ok, roots} <- roots(update) do
      {:ok,
       %{
         note_id: note_id,
         live_root_count: Enum.count(roots, fn {_client, live, _total} -> live > 0 end),
         root_count: length(roots),
         root_client_count: roots |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length(),
         lineage_lengths: Enum.map(roots, fn {_client, live, total} -> {live, total} end)
       }}
    end
  end

  defp roots(update) do
    case Native.yjs_root_inserts(update, CrdtBridge.text_name()) do
      {:ok, roots} -> {:ok, roots}
      :error -> {:error, :undecodable}
    end
  end

  # The doc as `CrdtTransport.read_delta/4` builds it (snapshot + tail), but
  # reading only the CRDT columns: content, title and path are never fetched or
  # decrypted, so a note whose facade will not decrypt still scans.
  defp crdt_state(user, vault, note_id) do
    {note, rows} =
      Repo.with_tenant!(user.id, fn ->
        note =
          Repo.one(
            from(n in Note,
              where:
                n.id == ^note_id and n.vault_id == ^vault.id and n.kind == "note" and
                  is_nil(n.deleted_at),
              select: struct(n, [:id, :dek_version, :crdt_state_ciphertext, :crdt_state_nonce])
            )
          )

        {note, note && CrdtPersistence.tail_rows(note_id, vault.id)}
      end)

    with %Note{} <- note,
         {:ok, snapshot} <- decrypt(note, user),
         :ok <- present(snapshot, rows),
         {:ok, doc} <- doc(snapshot),
         :ok <- replay(doc, user, note_id, rows),
         {:ok, update} <- Yex.encode_state_as_update(doc) do
      {:ok, update}
    else
      nil -> {:error, :not_found}
      {:error, reason} when reason in [:decrypt, :undecodable, :not_found] -> {:error, reason}
      _ -> {:error, :undecodable}
    end
  end

  # No snapshot and no tail in this vault: nothing to scan. Without this an
  # empty doc would scan as a clean note (a log-only note whose rows sit in a
  # foreign vault, #1318 shape, would read as healthy).
  defp present(nil, []), do: {:error, :not_found}
  defp present(_snapshot, _rows), do: :ok

  # Row by row, as `CrdtPersistence.apply_tail_rows/4` does, but telling the
  # two failures apart: a row that will not decrypt is `:decrypt`, one that
  # decrypts but will not apply is `:undecodable`. Either leaves the doc short.
  defp replay(doc, user, note_id, rows) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      case CrdtPersistence.decrypt_tail_row(row, user, note_id) do
        {:ok, update} when is_binary(update) ->
          if Yex.apply_update(doc, update) == :ok,
            do: {:cont, :ok},
            else: {:halt, {:error, :undecodable}}

        _ ->
          {:halt, {:error, :decrypt}}
      end
    end)
  end

  defp decrypt(note, user) do
    case Crypto.decrypt_crdt_state(note, user) do
      {:ok, snapshot} -> {:ok, snapshot}
      _ -> {:error, :decrypt}
    end
  end

  defp doc(snapshot) do
    case CrdtBridge.doc_from_state(snapshot) do
      {:ok, doc} -> {:ok, doc}
      _ -> {:error, :undecodable}
    end
  end

  defp tally({user, vault, note_id}, acc, scan, every) do
    acc =
      case safe_scan(scan, user, vault, note_id) do
        {:ok, %{live_root_count: live} = f} when live >= 2 -> %{acc | rivals: [f | acc.rivals]}
        {:ok, %{root_count: n} = f} when n >= 2 -> %{acc | suspects: [f | acc.suspects]}
        {:ok, _} -> acc
        {:error, reason} -> unreadable(acc, note_id, reason)
      end

    acc = %{acc | scanned: acc.scanned + 1, last_id: note_id}
    if rem(acc.scanned, every) == 0, do: progress(acc)
    acc
  end

  # Not swallowing: the raise is recorded against this note in `unreadable`,
  # as `:error`. One malformed note must not end a fleet-wide run, and the
  # exception (its module and message can carry decrypted bytes) stays out of
  # the result and the logs.
  defp safe_scan(scan, user, vault, note_id) do
    scan.(user, vault, note_id)
  rescue
    _ -> {:error, :error}
  end

  defp unreadable(acc, note_id, reason) do
    %{
      acc
      | unreadable: [%{note_id: note_id, reason: reason} | acc.unreadable],
        unreadable_count: acc.unreadable_count + 1
    }
  end

  defp progress(acc) do
    Logger.info(
      "lineage audit progress",
      Metadata.with_category(:info, :data,
        scanned: acc.scanned,
        rivals: length(acc.rivals),
        suspects: length(acc.suspects),
        unreadable: acc.unreadable_count,
        last_id: acc.last_id
      )
    )
  end

  # Ids off the maintenance pool (RLS would hide other tenants), then each
  # user's and vault's struct once, in two batched reads. A note counts when it
  # has a snapshot OR update-log rows: a never-checkpointed note lives only in
  # the log.
  defp targets(opts) do
    repo = Repo.maintenance()

    query =
      from(n in Note,
        as: :note,
        where:
          n.kind == "note" and is_nil(n.deleted_at) and
            (not is_nil(n.crdt_state_ciphertext) or
               exists(
                 from(l in CrdtUpdateLog,
                   where:
                     l.note_id == parent_as(:note).id and
                       l.vault_id == parent_as(:note).vault_id
                 )
               )),
        order_by: n.id,
        select: {n.user_id, n.vault_id, n.id}
      )

    query =
      Enum.reduce(opts, query, fn
        {:user_id, user_id}, q -> where(q, [n], n.user_id == ^user_id)
        {:after_id, id}, q -> where(q, [n], n.id > ^id)
        {:limit, limit}, q -> limit(q, ^limit)
        # :progress_every, :scan
        _, q -> q
      end)

    # `cross_tenant/1` is a no-op on the maintenance pool and load-bearing on
    # the `Repo` fallback (RLS not enforced), as in `OrphanSweep`.
    {rows, owners} =
      Repo.cross_tenant(fn ->
        rows = repo.all(query)
        user_ids = rows |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
        vault_ids = rows |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

        {rows,
         %{
           users: Map.new(repo.all(from(u in User, where: u.id in ^user_ids)), &{&1.id, &1}),
           vaults: Map.new(repo.all(from(v in Vault, where: v.id in ^vault_ids)), &{&1.id, &1})
         }}
      end)

    # A user or vault gone mid-run is nil here: scan_note/3 reports it
    # :owner_missing rather than raising.
    Enum.map(rows, fn {user_id, vault_id, note_id} ->
      {owners.users[user_id], owners.vaults[vault_id], note_id}
    end)
  end
end
