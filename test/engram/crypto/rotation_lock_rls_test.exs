defmodule Engram.Crypto.RotationLockRlsTest do
  @moduledoc """
  Pins the stale-takeover refusal against an ENFORCED row-level security
  policy. This is the one `skip_tenant_check` site in `RotationLock` that
  matters, and it is the only bucket-D site in the whole audit whose failure
  destroys data rather than doing nothing.

  ## The mechanism

  `half_state_pending?/1` counts `attachments` rows with a non-null
  `dek_version_pending`. Those rows' S3 blobs are encrypted under a DEK held
  only in the heap of the BEAM that crashed mid-rotation — unreachable. A fresh
  rotation mints a DIFFERENT DEK, so taking over the lock corrupts them
  irreversibly. Hence `{:error, :half_state_pending}`, and the runbook's
  manual-recovery path.

  `attachments` carries `FORCE ROW LEVEL SECURITY`. Unscoped, that count is
  FILTERED to 0 — no error, no warning — so `half_state_pending?/1` returns
  `false` and takeover proceeds. The guard inverts: the safety check designed
  to refuse becomes the thing that permits.

  Note the other four `skip_tenant_check` sites in that module are fine. They
  read and write `users`, which has no policy.

  ## Why `rotation_lock_test.exs` did not catch it

  It has the right assertion — `{:error, :half_state_pending}` at its Phase D
  block — and it passes today, because the suite connects as a superuser and a
  superuser bypasses RLS even under FORCE. Same assertion, same fixture; the
  only difference here is the dropped role. That is the whole lesson of
  `docs/context/rls-enforcement-testing-traps.md`.
  """
  use Engram.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Engram.RlsCase

  alias Engram.Accounts.User
  alias Engram.Attachments.Attachment
  alias Engram.Crypto.RotationLock
  alias Engram.Repo

  setup do
    user = insert(:user)
    vault = Engram.Fixtures.insert_vault!(user, "v")
    att = Engram.Fixtures.insert_attachment!(user, vault, %{path: "leaked.bin"})

    stale = DateTime.add(DateTime.utc_now(), -11 * 60, :second)

    Repo.update_all(
      from(u in User, where: u.id == ^user.id),
      [set: [dek_rotation_locked_at: stale]],
      skip_tenant_check: true
    )

    Repo.update_all(
      from(a in Attachment, where: a.id == ^att.id),
      [set: [dek_version_pending: 99]],
      skip_tenant_check: true
    )

    {:ok, user: user, stale: stale}
  end

  describe "acquire/1 under enforced RLS" do
    # CONTROL. Without it a green file cannot distinguish "the guard is scoped
    # correctly" from "the role drop never engaged" — and the fixtures above
    # write through `Fixtures.insert_*`, which opens its own `with_tenant`
    # whose SET LOCAL tenant leaks forward into this sandbox transaction. The
    # harness clears the tenant before dropping the role precisely so this
    # control is meaningful.
    test "control: the dropped role cannot see the half-rotated attachment", %{user: user} do
      outcome =
        as_prod_role(fn ->
          Repo.one(
            from(a in Attachment,
              where: a.user_id == ^user.id and not is_nil(a.dek_version_pending),
              select: count(a.id)
            ),
            skip_tenant_check: true
          )
        end)

      assert {:returned, 0} = outcome
    end

    test "refuses stale takeover when an attachment is half-rotated", %{user: user} do
      # Asserted on the RETURN VALUE, deliberately. The rolling-back harness
      # discards every write, so "dek_rotation_locked_at is unchanged" would
      # hold whether or not the policy filtered anything — vacuous against a
      # completely unscoped implementation. See the warning on
      # `Engram.RlsCase.as_prod_role/1`.
      #
      # Unscoped, this returns `{:ok, _}`: the count reads 0, so
      # `half_state_pending?/1` says false and the lock is taken over.
      assert {:returned, {:error, :half_state_pending}} =
               as_prod_role(fn -> RotationLock.acquire(user.id) end)
    end
  end
end
