defmodule Engram.Notes.RestWriteVersionFenceTest do
  @moduledoc """
  The REST/MCP note write must not clobber a checkpoint that committed after it
  read the row (#1335).

  `do_rewrite_note` reads `existing` at version N, merges CRDT state against
  `existing.crdt_state`, and then writes. The WHERE used to be the primary key
  alone, so a checkpoint committing in that gap was overwritten — `content` AND
  `crdt_state` both rolled back to the pre-checkpoint snapshot. The checkpoint
  has already pruned its tail rows, so those ops survive only in the live room's
  in-memory doc and die with the room.

  ## What these tests do and do NOT cover

  They do NOT reproduce the interleave. #1335 says so up front and it is
  correct: the sandbox owns ONE connection inside one never-committed
  transaction, so nothing can commit into the gap between this path's row read
  and its write. Reaching that gap needs a park point in production code, which
  is what made #1330 unshippable. Routes that looked like a way in and are not:
  `batch_upsert_notes` prefetches its `existing_by_hmac` map once (so a repeated
  path WOULD hold a stale struct) but rejects duplicate paths before the loop.

  What they DO cover is the regression surface of the fix itself, which is where
  a fence like this actually goes wrong:

    * a normal sequential write still lands and still merges convergently — a
      fence that rejects everything would "fix" the bug and break the product.
    * `version` advances exactly ONE step. `optimistic_lock/2` supplies the
      increment, so if the caller also set `:version` (as it did before this
      change) the manual value becomes the fence, misses on every write, burns
      the retry, and every REST write 409s. Both of these fail loudly if the two
      mechanisms are ever wired up together again.
  """
  use Engram.DataCase, async: false

  alias Engram.Crypto
  alias Engram.Crypto.DekCache
  alias Engram.Notes
  alias Engram.Notes.Note
  alias Engram.Repo

  setup do
    DekCache.invalidate_all()
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "VersionFence"})
    %{user: user, vault: vault}
  end

  test "a write that loses the fence re-merges instead of dropping the edit", ctx do
    %{user: user, vault: vault} = ctx

    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "converge.md", "content" => "line one"})

    v1 = reload(user, note.id).version

    # A second write goes through the same public path. It must land, and the
    # row's version must advance — proving the fence did not turn a normal
    # sequential write into a rejection.
    assert {:ok, _} =
             Notes.upsert_note(user, vault, %{
               "path" => "converge.md",
               "content" => "line one\nline two"
             })

    after_write = reload(user, note.id)
    assert after_write.version > v1

    {:ok, fresh} = Crypto.maybe_decrypt_note_fields(after_write, user)

    # CRDT merge is the conflict resolution on this path, so both lines survive.
    assert fresh.content =~ "line one"
    assert fresh.content =~ "line two"
  end

  test "the fenced write still bumps version exactly once", %{user: user, vault: vault} do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "once.md", "content" => "a"})
    v1 = reload(user, note.id).version

    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "once.md", "content" => "b"})
    v2 = reload(user, note.id).version

    # optimistic_lock/2 supplies the increment. If the caller ALSO set :version
    # the two would fight — the manual value would become the fence and always
    # miss. A single step proves only one of them is doing it.
    assert v2 == v1 + 1
  end

  defp reload(user, note_id) do
    {:ok, note} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note_id) end)
    note
  end
end
