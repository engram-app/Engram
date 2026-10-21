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
