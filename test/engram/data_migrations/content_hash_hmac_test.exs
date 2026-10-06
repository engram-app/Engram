defmodule Engram.DataMigrations.ContentHashHmacTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Engram.Fixtures

  alias Engram.Crypto
  alias Engram.DataMigrations.ContentHashHmac
  alias Engram.Workers.BackfillContentHashHmac

  setup do
    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "DM", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  defp insert_legacy_md5_note(user, vault) do
    content = "legacy body"
    md5 = :crypto.hash(:md5, content) |> Base.encode16(case: :lower)
    insert_note!(user, vault, %{"content" => content, "content_hash" => md5})
  end

  test "no legacy hashes: done, nothing enqueued" do
    assert ContentHashHmac.run_pass() == :done
    refute_enqueued(worker: BackfillContentHashHmac)
  end

  test "a legacy MD5 hash enqueues the backfill and stays open", %{user: user, vault: vault} do
    insert_legacy_md5_note(user, vault)
    assert ContentHashHmac.run_pass() == :more

    assert_enqueued(
      worker: BackfillContentHashHmac,
      args: %{"user_id" => user.id, "vault_id" => vault.id}
    )
  end

  test "jobs in flight: stays open without enqueueing again", %{user: user, vault: vault} do
    insert_legacy_md5_note(user, vault)
    assert ContentHashHmac.run_pass() == :more
    first = length(all_enqueued(worker: BackfillContentHashHmac))
    assert first == 1
    assert ContentHashHmac.run_pass() == :more
    assert length(all_enqueued(worker: BackfillContentHashHmac)) == first
  end
end
