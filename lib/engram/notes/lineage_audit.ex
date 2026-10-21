defmodule Engram.Notes.LineageAudit do
  @moduledoc """
  Read-only detector for notes whose CRDT body holds RIVAL lineages.

  A root insert is a body item written into an EMPTY text (no origin, no right
  origin). Yjs keeps deleted neighbours as origins, so a healthy note has root
  inserts from exactly one client, however it was edited. A second client means
  a device seeded the body into a doc it had never synced, and Yjs unioned the
  two copies: the fresh-device doubling (plugin #619), #846, #476. The count is
  the source of truth; reading the text for "old body + edit" is triage only.

  From prod (Mix tasks are not in the release):

      bin/engram rpc 'Engram.Notes.LineageAudit.run() |> IO.inspect(limit: :infinity)'
      bin/engram rpc 'Engram.Notes.LineageAudit.run(user_id: "...") |> IO.inspect()'

  Output is note ids and counts only: no content, titles or paths, and nothing
  is logged per note. Writes nothing. Reads each doc the way `crdt_doc_state`
  does (snapshot + update-log tail), one note at a time.
  """
  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Native
  alias Engram.Notes.{CrdtBridge, CrdtTransport, Note}
  alias Engram.Repo
  alias Engram.Vaults.Vault

  @type finding :: %{
          note_id: String.t(),
          root_client_count: non_neg_integer(),
          lineage_lengths: [non_neg_integer()]
        }

  @doc """
  Scan every live note with CRDT state (or one user's, `user_id:`). Returns
  `{:ok, %{scanned, unreadable, rivals: [finding]}}`, or `{:error,
  :no_maintenance_repo}` where RLS would silently hide every row.
  """
  @spec run(keyword()) ::
          {:ok, %{scanned: non_neg_integer(), unreadable: non_neg_integer(), rivals: [finding]}}
          | {:error, :no_maintenance_repo}
  def run(opts \\ []) do
    if Repo.maintenance() == Repo and Engram.Repo.TenancyGuard.enforced?() do
      {:error, :no_maintenance_repo}
    else
      {:ok, opts |> targets() |> Enum.reduce(%{scanned: 0, unreadable: 0, rivals: []}, &tally/2)}
    end
  end

  @doc "One note. `{:ok, finding}` or `{:error, reason}`."
  @spec scan_note(User.t(), Vault.t(), String.t()) :: {:ok, finding} | {:error, term()}
  def scan_note(user, vault, note_id) do
    with {:ok, %{update: update}} <- CrdtTransport.read_delta(user, vault, note_id, nil),
         {:ok, roots} <- Native.yjs_root_inserts(update, CrdtBridge.text_name()) do
      clients = roots |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      {:ok,
       %{
         note_id: note_id,
         root_client_count: length(clients),
         lineage_lengths: Enum.map(roots, &elem(&1, 1))
       }}
    else
      :error -> {:error, :undecodable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp tally({user, vault, note_id}, acc) do
    case scan_note(user, vault, note_id) do
      {:ok, %{root_client_count: n} = f} when n > 1 ->
        %{acc | scanned: acc.scanned + 1, rivals: [f | acc.rivals]}

      {:ok, _} ->
        %{acc | scanned: acc.scanned + 1}

      {:error, _} ->
        %{acc | scanned: acc.scanned + 1, unreadable: acc.unreadable + 1}
    end
  end

  # Ids off the maintenance pool (RLS would hide other tenants), then each
  # user's and vault's struct once, in two batched reads.
  defp targets(opts) do
    repo = Repo.maintenance()

    query =
      from(n in Note,
        where: n.kind == "note" and is_nil(n.deleted_at) and not is_nil(n.crdt_state_ciphertext),
        order_by: [n.user_id, n.vault_id],
        select: {n.user_id, n.vault_id, n.id}
      )

    query =
      case Keyword.get(opts, :user_id) do
        nil -> query
        user_id -> where(query, [n], n.user_id == ^user_id)
      end

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

    Enum.map(rows, fn {user_id, vault_id, note_id} ->
      {owners.users[user_id], owners.vaults[vault_id], note_id}
    end)
  end
end
