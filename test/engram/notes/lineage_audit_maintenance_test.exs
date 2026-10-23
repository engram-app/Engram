defmodule Engram.Notes.LineageAuditMaintenanceTest do
  @moduledoc """
  Proves `LineageAudit.run/1` finds every tenant's notes through the
  maintenance pool (trap 9 of docs/context/rls-enforcement-testing-traps.md).

  The rest of the suite connects as a superuser and never starts
  `Engram.Repo.Maintenance`, so an audit whose target read moved back onto
  `Repo` would pass there. Here the app pool runs as `engram_app` with no
  tenant, where a plain read sees no note at all (the CONTROL test), while a
  real maintenance pool runs on its own superuser connection. Only a target
  read through that pool can list both tenants' notes; each note is then read
  under its own tenant on the app pool, as in prod.

  The maintenance pool is a second connection, so the fixtures are COMMITTED
  outside the sandbox and deleted on exit.
  """
  use Engram.DataCase, async: false

  import Engram.RlsCase

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Crypto.Envelope
  alias Engram.Fixtures
  alias Engram.Notes.{CrdtBridge, LineageAudit, Note}
  alias Engram.Repo
  alias Engram.Repo.Maintenance

  setup do
    config = Keyword.merge(Repo.config(), pool: DBConnection.ConnectionPool, pool_size: 1)
    start_supervised!({Maintenance, config})

    Application.put_env(:engram, :maintenance_repo_enabled, true)
    on_exit(fn -> Application.delete_env(:engram, :maintenance_repo_enabled) end)

    owners = Sandbox.unboxed_run(Repo, fn -> for _ <- 1..2, do: doubled_note!() end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        for {user, vault, _note_id} <- owners do
          # The vault delete cascades to its notes; then the user can go.
          Repo.delete!(vault, skip_tenant_check: true)
          Repo.delete!(user, skip_tenant_check: true)
        end
      end)
    end)

    %{note_ids: Enum.map(owners, &elem(&1, 2))}
  end

  # A committed tenant whose one note's CRDT state is a doubled body (two live
  # roots). The snapshot is sealed with no AAD, which `dek_version: 1` reads.
  defp doubled_note! do
    {:ok, user} = Fixtures.user_with_dek_fixture()
    vault = Fixtures.insert_vault!(user, "Audit")
    note = Fixtures.insert_note!(user, vault, %{path: "Doubled.md", content: "a\n"})

    doc = CrdtBridge.new_doc()
    CrdtBridge.ingest_plaintext(doc, "a\n")
    rival = CrdtBridge.new_doc()
    CrdtBridge.ingest_plaintext(rival, "a\nb\n")
    {:ok, rival_state} = Yex.encode_state_as_update(rival)
    :ok = Yex.apply_update(doc, rival_state)
    {:ok, state} = Yex.encode_state_as_update(doc)

    {:ok, dek} = Engram.Crypto.get_dek(user)
    {ct, nonce} = Envelope.encrypt(state, dek, <<>>)

    {1, _} =
      Repo.update_all(
        from(n in Note, where: n.id == ^note.id),
        [set: [crdt_state_ciphertext: ct, crdt_state_nonce: nonce, dek_version: 1]],
        skip_tenant_check: true
      )

    {user, vault, note.id}
  end

  test "CONTROL: the app pool as engram_app with no tenant sees no note", %{note_ids: ids} do
    assert {:returned, 0} =
             as_prod_role(fn ->
               Repo.aggregate(from(n in Note, where: n.id in ^ids), :count,
                 skip_tenant_check: true
               )
             end)
  end

  test "a run as engram_app still finds both tenants' rivals", %{note_ids: ids} do
    assert {:returned, {:ok, %{rivals: rivals, unreadable: unreadable}}} =
             as_prod_role(fn -> LineageAudit.run() end)

    found = Enum.map(rivals, & &1.note_id)
    for id <- ids, do: assert(id in found, "#{inspect(unreadable)}")
  end
end
