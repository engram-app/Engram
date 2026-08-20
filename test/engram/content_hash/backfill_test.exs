defmodule Engram.ContentHash.BackfillTest do
  # Calls `enqueue_all/0` directly — no `Mix.Task.run/1` anywhere in the path.
  # That is the whole point of #1311: `Mix` is not loaded in a release, so the
  # documented recovery rpc could never have worked while the logic lived in
  # the mix task.
  #
  # async: true — this suite only inspects the oban_jobs table via
  # assert_enqueued/refute_enqueued and never drives a real dispatch, so it
  # needs no serialization. (Contrast Engram.Workers.BackfillContentHashHmacTest,
  # which IS async: false because Oban.drain_queue/1 needs a stable sandbox
  # connection owner — see docs/context/channel-parallelism-db-pool.md.)
  use Engram.DataCase, async: true
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query, only: [from: 2]
  import Engram.Fixtures

  alias Engram.Attachments.Attachment
  alias Engram.ContentHash.Backfill
  alias Engram.Crypto
  alias Engram.Repo
  alias Engram.Workers.BackfillContentHashHmac

  @start_cursor "00000000-0000-0000-0000-000000000000"

  setup do
    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})

    {:ok, vault, _} =
      Engram.Vaults.register_vault(user, "ContentHashBackfill", Ecto.UUID.generate())

    %{user: user, vault: vault}
  end

  test "enqueues a notes job for a vault holding a legacy MD5 hash", %{user: user, vault: vault} do
    insert_legacy_note!(user, vault)

    assert %{notes: 1, attachments: 0} = Backfill.enqueue_all()

    # `cursor` is asserted explicitly: assert_enqueued matches args as a subset,
    # so without it a malformed @start_cursor would sail through here and only
    # blow up in prod, where the worker feeds it straight into a uuid comparison.
    assert_enqueued(
      worker: BackfillContentHashHmac,
      args: %{
        "user_id" => user.id,
        "vault_id" => vault.id,
        "scope" => "notes",
        "cursor" => @start_cursor
      }
    )
  end

  test "enqueues an attachments job for a vault holding a legacy MD5 hash", %{
    user: user,
    vault: vault
  } do
    insert_legacy_attachment!(user, vault)

    assert %{notes: 0, attachments: 1} = Backfill.enqueue_all()

    assert_enqueued(
      worker: BackfillContentHashHmac,
      args: %{
        "user_id" => user.id,
        "vault_id" => vault.id,
        "scope" => "attachments",
        "cursor" => @start_cursor
      }
    )
  end

  test "enqueues both scopes independently for the same vault", %{user: user, vault: vault} do
    insert_legacy_note!(user, vault)
    insert_legacy_attachment!(user, vault)

    assert %{notes: 1, attachments: 1} = Backfill.enqueue_all()
  end

  test "enqueues nothing when every hash is already HMAC", %{user: user, vault: vault} do
    content = "already hashed"
    {:ok, content_key} = Crypto.dek_content_hash_key(user)

    insert_note!(user, vault, %{
      "content" => content,
      "content_hash" => Crypto.hmac_content_hash(content_key, content)
    })

    # insert_attachment! already writes an HMAC content_hash.
    insert_attachment!(user, vault)

    assert %{notes: 0, attachments: 0} = Backfill.enqueue_all()

    refute_enqueued(worker: BackfillContentHashHmac)
  end

  defp insert_legacy_note!(user, vault) do
    content = "# legacy\nbody"
    insert_note!(user, vault, %{"content" => content, "content_hash" => md5(content)})
  end

  # insert_attachment! always computes an HMAC hash, so the legacy state has to
  # be written back over it.
  defp insert_legacy_attachment!(user, vault) do
    content = <<9, 8, 7, 6>>
    att = insert_attachment!(user, vault, %{"content" => content})

    {1, _} =
      Repo.update_all(
        from(a in Attachment, where: a.id == ^att.id),
        [set: [content_hash: md5(content)]],
        skip_tenant_check: true
      )

    att
  end

  defp md5(content), do: :crypto.hash(:md5, content) |> Base.encode16(case: :lower)
end
