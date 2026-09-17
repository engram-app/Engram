defmodule Engram.Crypto.UserDekRotationRlsTest do
  @moduledoc """
  Proves that per-user DEK rotation cannot report success while having
  re-encrypted nothing.

  ## The failure this pins

  `run_phases/2` is a single `with` chain: nine sweeps, then `final_flip/3`.
  Each sweep drives `sweep_table_loop/4`, whose cursor reads

      Repo.all(query, skip_tenant_check: true)

  with no `app.current_tenant` set. `skip_tenant_check: true` suppresses only
  Engram's application-level guard in `Repo.prepare_query/3`; it does not set
  the tenant and does not touch Postgres. Every swept table carries FORCE ROW
  LEVEL SECURITY, so with no tenant the policy compares against NULL and
  filters every row.

  `sweep_table_loop/4` then does:

      case ids do
        [] -> :ok

  An empty first batch is indistinguishable from "swept everything". All nine
  sweeps return `:ok`, the `with` chain proceeds, and `final_flip/3` writes
  `users` — which has NO RLS policy, so that write genuinely lands. The user's
  `encrypted_dek` is replaced with a key that decrypts none of their data, and
  the run logs "T3.7 per-user DEK rotation complete".

  Unrecoverable once the old key is gone.

  ## Why the existing suite does not catch this

  `user_dek_rotation_test.exs` already asserts "every note re-encrypts under
  the new DEK" and would fail on exactly this. It passes because the test and
  CI databases connect as `engram`, the cluster bootstrap SUPERUSER, and
  superusers bypass RLS even when it is FORCED. The rows are visible in test
  and invisible in prod.

  So this file drops to `engram_app` (no SUPERUSER, no BYPASSRLS, created by
  `mix engram.prepare_database`, which both the `mix test` alias and CI run)
  before calling rotation. That mirrors prod, where the app connects as
  `engram_admin` — the table owner, which FORCE deliberately binds anyway.

  Verified against the prod database on 2026-09-15: all 11 tenant tables have
  `relrowsecurity` AND `relforcerowsecurity` true, and no application role
  holds `rolbypassrls`.

  ## Severity

  Latent, not live. `Engram.Workers.RotateUserDek` has no Oban metric series
  in prod, i.e. it has never executed there. This test exists so that stays
  true by choice rather than by luck — the first operator to run a rotation is
  otherwise the one who discovers it.

  Not tagged `:integration`: that tag is excluded unless `INTEGRATION_TESTS=1`,
  which CI never sets, so a tagged regression test would guard nothing.
  `async: false` because the role change is connection-global, and `RESET ROLE`
  is mandatory or `engram_app` leaks into the sandbox transaction.
  """

  use Engram.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  # A real rotation runs with no tenant set: neither the Oban worker
  # (`workers/rotate_user_dek.ex:61`) nor the mix task wraps the call in
  # `Repo.with_tenant/2`. Hence the dropped-role harness, and the COMMITTING
  # variant —
  # every assertion here reads back persisted state via `reload_note/1` and
  # `reload_user/1` below.
  #
  # KNOWN COVERAGE LIMIT, and the comment here previously asserted the
  # opposite. `user_dek_rotation.ex` contains EIGHT `with_tenant` calls, and
  # the first one `rotate_user/1` reaches is `sweep_table_loop/4`. Its exit runs
  # `set_config('role', 'none', true)`, which under the sandbox leaks forward
  # into the enclosing transaction and reverts the role to the superuser. So
  # only the FIRST sweep runs enforced; `sweep_vaults`, the vault-index sweeps,
  # `sweep_attachments`, `sweep_note_links`, `clear_chunk_context_hmacs` and
  # `final_flip` all run unenforced here. Deleting the `with_tenant` from any
  # of those leaves these tests green. Driving the sweeps individually under
  # the harness is what would close it.
  #
  # The local copy this replaced put `RESET ROLE` in an `after`, which is the
  # one spelling the other files' comments warn against: on the raise path the
  # transaction is already aborted, so the reset fails with 25P02 and buries
  # the real error. Nothing in this file raises today, so it was latent rather
  # than live.
  import Engram.RlsCase

  alias Engram.Accounts.User
  alias Engram.Crypto
  alias Engram.Crypto.UserDekRotation
  alias Engram.Notes.Note
  alias Engram.Repo

  setup do
    # sweep_qdrant/3 runs inside the phase chain; stub it so this test fails on
    # RLS behaviour rather than on a missing Qdrant. Mirrors the module-level
    # setup in user_dek_rotation_test.exs.
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    Bypass.stub(bypass, "POST", "/collections/engram_notes/points/scroll", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"result" => %{"points" => [], "next_page_offset" => nil}})
      )
    end)

    {:ok, user} = Engram.Fixtures.user_with_dek_fixture(dek_version: 1)
    vault = Engram.Fixtures.insert_vault!(user, "RlsRotationVault")

    note =
      Engram.Fixtures.insert_note!(user, vault, %{path: "alpha.md", content: "alpha content"})

    {:ok, user: user, vault: vault, note: note}
  end

  # Reads run OUTSIDE the dropped-role block, as the superuser. Reading them
  # inside would filter them too, and the test would pass while seeing nothing
  # — the same silent-empty failure it is meant to detect.
  defp reload_note(id),
    do: Repo.one!(from(n in Note, where: n.id == ^id), skip_tenant_check: true)

  defp reload_user(id),
    do: Repo.one!(from(u in User, where: u.id == ^id), skip_tenant_check: true)

  describe "rotate_user/1 under FORCE RLS" do
    # CONTROL. Without this, a green result on the tests below is ambiguous:
    # "rotation is correctly scoped" and "the role drop never engaged, so RLS
    # was never in play" look identical. This asserts the harness actually
    # bites before anything is concluded from it.
    test "control: the dropped role cannot see the user's rows", %{user: user, note: note} do
      visible =
        as_prod_role_committing(fn ->
          Repo.one(
            from(n in Note, where: n.user_id == ^user.id, select: count(n.id)),
            skip_tenant_check: true
          )
        end)

      assert visible == 0,
             """
             Harness is not engaging RLS, so every other assertion in this file is meaningless.

               notes visible as engram_app with no tenant: #{inspect(visible)} (expected 0)
               note that exists:                            #{note.id}

             Either SET LOCAL ROLE did not apply to this connection, or the
             role has BYPASSRLS, or the table is no longer FORCE'd.
             """
    end

    test "does not flip the user while leaving rows wrapped under the old DEK",
         %{user: user, note: note} do
      result = as_prod_role_committing(fn -> UserDekRotation.rotate_user(user.id) end)

      reloaded_note = reload_note(note.id)
      reloaded_user = reload_user(user.id)

      # Guard against a VACUOUS pass. The invariant below also holds when
      # rotation never ran at all (both versions stay 1) — e.g. an early
      # `{:error, :rotation_in_progress}` or a failed `get_dek`. Without these
      # two assertions this test would report success having exercised
      # nothing, which is the same class of mistake it exists to catch.
      assert result == :ok,
             "rotation did not complete, so the invariant below proves nothing: #{inspect(result)}"

      assert reloaded_user.dek_version == 2,
             "rotation reported :ok but never flipped the user (still v#{reloaded_user.dek_version}); the test would pass vacuously"

      # The invariant that matters: whatever version the user now claims, the
      # user's rows must actually be wrapped at. Broken gives note=1 user=2.
      assert reloaded_note.dek_version == reloaded_user.dek_version,
             """
             DEK rotation left data behind.

               rotate_user/1 returned: #{inspect(result)}
               users.dek_version:      #{reloaded_user.dek_version}
               notes.dek_version:      #{reloaded_note.dek_version}

             A user flipped to a new DEK while their notes are still wrapped
             under the old one means the sweeps matched zero rows and reported
             success anyway. Once the previous key is retired those rows are
             unrecoverable.
             """
    end

    test "the note still decrypts after a rotation that reported success",
         %{user: user, note: note} do
      _ = as_prod_role_committing(fn -> UserDekRotation.rotate_user(user.id) end)

      reloaded_user = reload_user(user.id)
      reloaded_note = reload_note(note.id)

      assert {:ok, decrypted} = Crypto.maybe_decrypt_note_fields(reloaded_note, reloaded_user)

      assert decrypted.content == "alpha content",
             "note did not survive rotation: content is no longer readable under the user's current DEK"
    end
  end
end
