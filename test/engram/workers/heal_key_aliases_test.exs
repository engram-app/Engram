defmodule Engram.Workers.HealKeyAliasesTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query

  alias Engram.Crypto
  alias Engram.DataMigrations.KeyAliases, as: Migration
  alias Engram.Notes.{KeyAliases, Note, OkfFields}
  alias Engram.Workers.{DataMigrationsRunner, HealKeyAliases, RebuildStaleNote}

  setup do
    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user, is_default: true)
    {:ok, fk} = Crypto.dek_filter_key(user)
    %{user: user, vault: vault, fk: fk}
  end

  # A note indexed at its content under an older alias table: `type_hmac` as
  # that table read it, stamped with another version.
  defp indexed(ctx, content, type) do
    note = Engram.Fixtures.insert_note!(ctx.user, ctx.vault, %{content: content})
    hmac = type && Crypto.hmac_field(ctx.fk, OkfFields.normalize_type(type))

    Repo.update_all(
      from(n in Note, where: n.id == ^note.id),
      [set: [embed_hash: note.content_hash, type_hmac: hmac, key_alias_version: 1]],
      skip_tenant_check: true
    )

    note
  end

  defp row(note), do: Repo.get!(Note, note.id, skip_tenant_check: true)

  test "a bump heals an affected note and leaves an unaffected note untouched", ctx do
    # `種類` was not an alias under the old table, so the row has no type.
    affected = indexed(ctx, "---\n種類: 会議\n---\n# A\n", nil)
    untouched = indexed(ctx, "---\ntype: 会議\n---\n# B\n", "会議")
    before = row(untouched)

    assert HealKeyAliases.enqueue_missing() == 1
    assert :ok = perform_job(HealKeyAliases, %{"user_id" => ctx.user.id})

    assert row(affected).type_hmac == Crypto.hmac_field(ctx.fk, "会議")

    assert_enqueued(
      worker: RebuildStaleNote,
      args: %{note_id: affected.id, upgrade: true, key_aliases: true}
    )

    refute_enqueued(worker: RebuildStaleNote, args: %{note_id: untouched.id})
    after_ = row(untouched)
    assert after_.key_alias_version == KeyAliases.version()
    assert Map.delete(after_, :key_alias_version) == Map.delete(before, :key_alias_version)
  end

  # Review of #2126: the heal re-encrypts type/description/resource. Written
  # under a DEK a rotation is replacing, they would be unreadable afterwards.
  test "snoozes while the user's DEK rotation holds the lock, writing nothing", ctx do
    affected = indexed(ctx, "---\n種類: 会議\n---\n# A\n", nil)

    Repo.update_all(from(u in Engram.Accounts.User, where: u.id == ^ctx.user.id),
      set: [dek_rotation_locked_at: DateTime.utc_now()]
    )

    assert {:snooze, 60} = perform_job(HealKeyAliases, %{"user_id" => ctx.user.id})
    assert row(affected).type_hmac == nil
    assert row(affected).key_alias_version == 1
    refute_enqueued(worker: RebuildStaleNote)
  end

  # The re-index is maintenance: it queues behind the v5 pass, not ahead of it.
  test "queues the re-index at backfill priority", ctx do
    affected = indexed(ctx, "---\n種類: 会議\n---\n# A\n", nil)
    assert :ok = perform_job(HealKeyAliases, %{"user_id" => ctx.user.id})

    assert_enqueued(
      worker: RebuildStaleNote,
      args: %{note_id: affected.id},
      priority: Engram.Workers.EmbedNote.backfill_priority()
    )
  end

  # A chain inserts its own successor while it executes, so `unique` cannot
  # stop a second chain for that user: the enqueue skips executing users.
  test "enqueue_missing skips a user whose chain is executing", ctx do
    _ = indexed(ctx, "---\ntype: x\n---\n# C\n", "x")

    {:ok, job} = Oban.insert(HealKeyAliases.new(%{"user_id" => ctx.user.id}))
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "executing"])

    _ = HealKeyAliases.enqueue_missing()

    assert [_only] =
             Repo.all(from(j in Oban.Job, where: j.worker == "Engram.Workers.HealKeyAliases"))
  end

  # The plain deploy: every row is unstamped, and a heal re-chunks the note
  # under the unstamped v5 chunker (paid Voyage). It runs only while the v5
  # rebuild is `on`, where the ledger meters what it spends.
  test "the migration is off until the v5 rebuild is on", ctx do
    _ = indexed(ctx, "---\n種類: 会議\n---\n# A\n", nil)

    refute Migration.enabled?()

    Engram.ServiceConfig.put_override(:index_rebuild, "on")
    # `on` needs an open ledger (no budget reads as halted).
    Engram.Cache.clear_local(:rebuild)
    Repo.query!("DELETE FROM rebuild_ledger")
    Engram.Rebuild.set_budget(1_000_000)
    assert Engram.Rebuild.mode() == :on
    assert Migration.enabled?()
  end

  test "the migration is done once every note is read under the current table", ctx do
    assert Migration in DataMigrationsRunner.migrations()
    assert Migration.name() == "key_aliases:#{KeyAliases.version()}"

    note = indexed(ctx, "---\ntype: x\n---\n# C\n", "x")
    assert {:more, users: 1} = Migration.run_pass()

    Repo.update_all(
      from(n in Note, where: n.id == ^note.id),
      [set: [key_alias_version: KeyAliases.version()]],
      skip_tenant_check: true
    )

    assert Migration.run_pass() == :done
  end
end
