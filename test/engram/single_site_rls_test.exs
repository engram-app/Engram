defmodule Engram.SingleSiteRlsTest do
  @moduledoc """
  Three one-site bucket-D fixes, grouped because each is too small for its own
  file and they share the same user + vault fixture. Precedent:
  `workers/worker_tenant_args_rls_test.exs` groups by concern rather than by
  module.

  All three read a tenant table with `skip_tenant_check: true` and no enclosing
  `with_tenant/2`, and all three fail silently in a different shape:

    * `Auth.DeviceFlow.authorize_device/3` reads `vaults` to validate the
      selection. Filtered it returns nil and the caller gets
      `{:error, :vault_not_found}` — device linking refuses a vault the user
      owns. The one LOUD failure of the three, though it blames the wrong thing.
    * `Workers.VaultDeletedEmail.perform/1` reads the deleted `vaults` row.
      Filtered it is nil, the `cond` falls into its `is_nil` arm, and the worker
      returns `:ok` having sent NOTHING. The user is never told their vault is
      scheduled for purge, and Oban records a success.
    * `KeywordIndex.Stats.avgdl/2` averages `chunks.token_count`. Filtered the
      aggregate is nil and the function falls back to `@default_avgdl` (100.0),
      so every BM25 weight in the vault is length-normalized against a
      bootstrap constant instead of the vault's real average. No error, just
      quietly worse ranking — and `Indexing.prepare_index/3` is documented as
      running OUTSIDE the per-note `with_tenant/2` ("HTTP/CPU only, no DB
      writes"), which is what leaves this read unscoped.

  `avgdl` is the one site that could not be fixed in place: nothing in `Stats`
  has a `user_id`, and the `vaults` lookup that would supply one is itself
  under the policy. So it took the tenant as a new first argument — `avgdl/1`
  became `avgdl/2` — and the scope sits in `compute_avgdl/2`, the cache-miss
  path, so a cache hit still costs no transaction.
  """
  use Engram.DataCase, async: false

  import Ecto.Query
  import Engram.RlsCase
  import Mox

  alias Engram.Auth.DeviceFlow
  alias Engram.KeywordIndex.Stats
  alias Engram.Notes.Chunk
  alias Engram.Repo
  alias Engram.Vaults.Vault
  alias Engram.Workers.VaultDeletedEmail

  setup :verify_on_exit!

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)

    %{user: user, vault: vault}
  end

  # CONTROL. Without it a green file cannot distinguish "correctly scoped" from
  # "the role drop never engaged".
  test "control: the dropped role cannot see the user's vault", %{vault: vault} do
    assert {:returned, 0} =
             as_prod_role(fn ->
               Repo.one(
                 from(v in Vault, where: v.id == ^vault.id, select: count(v.id)),
                 skip_tenant_check: true
               )
             end)
  end

  describe "DeviceFlow.authorize_device/3" do
    test "authorizes against a vault the user owns", %{user: user, vault: vault} do
      auth = insert(:device_authorization, status: "pending")

      outcome =
        as_prod_role(fn -> DeviceFlow.authorize_device(auth.user_code, user, vault.id) end)

      assert {:returned, {:ok, _}} = outcome,
             """
             authorize_device/3 refused a vault the user owns — the `vaults`
             read was filtered, so device linking fails with :vault_not_found
             and blames the vault rather than the scoping.

               got: #{inspect(outcome)}
             """
    end
  end

  describe "VaultDeletedEmail.perform/1" do
    setup %{user: user} do
      deleted = insert(:vault, user: user, deleted_at: DateTime.utc_now(:second))

      prev = Application.get_env(:engram, :email_provider)
      Application.put_env(:engram, :email_provider, Engram.Email.ProviderMock)

      on_exit(fn ->
        if is_nil(prev),
          do: Application.delete_env(:engram, :email_provider),
          else: Application.put_env(:engram, :email_provider, prev)
      end)

      # `stub`, not `expect`: an unmet `expect` fails in `verify_on_exit!` with
      # a message about invocation counts, which buries the actual finding. The
      # `assert_received` below says what went wrong instead.
      test_pid = self()

      stub(Engram.Email.ProviderMock, :send, fn to, subject, _html, _opts ->
        send(test_pid, {:mail_sent, to, subject})
        :ok
      end)

      %{deleted: deleted}
    end

    test "emails the user about their deleted vault", %{user: user, deleted: deleted} do
      assert {:returned, :ok} =
               as_prod_role(fn ->
                 VaultDeletedEmail.perform(%Oban.Job{
                   args: %{"user_id" => user.id, "vault_id" => deleted.id}
                 })
               end)

      assert_received {:mail_sent, _to, _subject},
                      "no email was sent: the `vaults` read was filtered, the worker's " <>
                        "`is_nil(vault)` arm swallowed it, and Oban recorded a success"
    end
  end

  describe "KeywordIndex.Stats.avgdl/2" do
    setup %{user: user, vault: vault} do
      note = Engram.Fixtures.insert_note!(user, vault, %{path: "Chunked.md"})

      for {position, tokens} <- [{0, 40}, {1, 60}] do
        %Chunk{}
        |> Chunk.changeset(%{
          position: position,
          char_start: position * 100,
          char_end: position * 100 + 99,
          token_count: tokens,
          qdrant_point_id: Ecto.UUID.generate(),
          note_id: note.id,
          user_id: user.id,
          vault_id: vault.id
        })
        |> Repo.insert!(skip_tenant_check: true)
      end

      # Per-node ETS cache with a TTL: a value cached by an earlier test would
      # make this assert nothing.
      :ok = Stats.evict(vault.id)
      on_exit(fn -> Stats.evict(vault.id) end)

      %{note: note}
    end

    test "averages the vault's real token counts, not the bootstrap default",
         %{user: user, vault: vault} do
      outcome = as_prod_role(fn -> Stats.avgdl(user.id, vault.id) end)

      assert {:returned, 50.0} = outcome,
             """
             avgdl returned the @default_avgdl bootstrap (100.0) for a vault whose
             two chunks average 50 — the `chunks` aggregate was filtered to nil.
             Every BM25 weight in the vault is then normalized against a made-up
             average, with nothing logged.

               got: #{inspect(outcome)}
             """
    end
  end
end
