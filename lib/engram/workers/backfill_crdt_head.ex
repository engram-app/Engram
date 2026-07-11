defmodule Engram.Workers.BackfillCrdtHead do
  @moduledoc """
  Warm the `notes.crdt_head` column so `CrdtTransport.vault_heads/2` never pays
  an O(notes) doc-rebuild on a live poll.

  Per (user, vault): walks notes whose `crdt_head` is still NULL, rebuilds each
  doc ONCE via `CrdtTransport.backfill_head/3` (which persists the computed
  head), cursor-batched, re-enqueuing itself until the vault is drained.

  Idempotent: the `is_nil(crdt_head)` predicate drops any note already set (by
  `update_v1` or a prior batch), so a retry or a second `enqueue_all/0` never
  re-rebuilds a note.

  Enqueue post-deploy via release rpc (no Mix in the release — plain function):

      docker exec engram-saas /app/bin/engram rpc 'Engram.Workers.BackfillCrdtHead.enqueue_all()'
  """

  # No `unique`: a cursor worker re-enqueues its own successor mid-run, which
  # collides with `:incomplete` uniqueness (the running job counts) and would
  # drop the successor, killing the loop after one batch. The `is_nil(crdt_head)`
  # filter already makes the work idempotent, so a duplicate enqueue_all just
  # does converging, harmless re-scans — acceptable for a one-time backfill.
  use Oban.Worker, queue: :crypto_backfill, max_attempts: 5

  import Ecto.Query

  alias Engram.Accounts
  alias Engram.Crypto.RotationGate
  alias Engram.Notes.{CrdtTransport, Note}
  alias Engram.Repo
  alias Engram.Vaults

  @default_batch_size 100
  @start_cursor "00000000-0000-0000-0000-000000000000"

  # Config-overridable so a test can exercise the cursor re-enqueue loop without
  # inserting @default_batch_size+1 notes. Prod uses the default.
  defp batch_size,
    do: Application.get_env(:engram, :crdt_head_backfill_batch_size, @default_batch_size)

  @doc "Enqueue one job per (user, vault) that still has a NULL-crdt_head note. Returns the count."
  @spec enqueue_all() :: non_neg_integer()
  def enqueue_all do
    pairs =
      from(n in Note,
        where: is_nil(n.crdt_head) and is_nil(n.deleted_at),
        group_by: [n.user_id, n.vault_id],
        select: {n.user_id, n.vault_id}
      )
      |> Repo.all(skip_tenant_check: true)

    Enum.each(pairs, fn {user_id, vault_id} ->
      %{"user_id" => user_id, "vault_id" => vault_id, "cursor" => @start_cursor}
      |> __MODULE__.new()
      |> Oban.insert()
    end)

    length(pairs)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "vault_id" => vault_id} = args}) do
    cursor = args["cursor"] || @start_cursor

    # Gate DEK-touching work during a per-user rotation window (parity with
    # BackfillContentHashHmac): backfill_head -> load_doc decrypts crdt_state,
    # which can transiently fail mid-rotation. crdt_head itself is rotation-
    # invariant (a hash of plaintext clock counts), so this is quiet-during-
    # rotation, not a correctness gate.
    case RotationGate.check(user_id) do
      {:error, :rotation_in_progress} -> {:snooze, 60}
      {:error, :user_not_found} -> {:discard, :user_deleted}
      :ok -> run(user_id, vault_id, cursor)
    end
  end

  defp run(user_id, vault_id, cursor) do
    case Accounts.get_user(user_id) do
      nil ->
        {:discard, :user_deleted}

      user ->
        case Vaults.get_vault(user, vault_id) do
          {:ok, vault} -> backfill_batch(user, vault, cursor)
          {:error, :not_found} -> {:discard, :vault_deleted}
        end
    end
  end

  defp backfill_batch(user, vault, cursor) do
    limit = batch_size()

    {:ok, ids} =
      Repo.with_tenant(user.id, fn ->
        from(n in Note,
          where:
            n.vault_id == ^vault.id and n.id > ^cursor and is_nil(n.crdt_head) and
              is_nil(n.deleted_at),
          order_by: [asc: n.id],
          select: n.id,
          limit: ^limit
        )
        |> Repo.all()
      end)

    # backfill_head/3 manages its own tenant scoping (load_doc + store_head), so
    # it is called outside the batch-select transaction, once per note.
    Enum.each(ids, fn id -> CrdtTransport.backfill_head(user, vault, id) end)

    if length(ids) == limit do
      _ =
        %{"user_id" => user.id, "vault_id" => vault.id, "cursor" => List.last(ids)}
        |> __MODULE__.new()
        |> Oban.insert()
    end

    :ok
  end
end
