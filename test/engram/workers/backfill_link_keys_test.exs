defmodule Engram.Workers.BackfillLinkKeysTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Attachments.Attachment
  alias Engram.DataMigrations.LinkResolutionKeys
  alias Engram.Fixtures
  alias Engram.Links
  alias Engram.Links.NoteLink
  alias Engram.Notes.Note
  alias Engram.Workers.BackfillLinkKeys

  setup do
    {:ok, user} = Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    note = Fixtures.insert_note!(user, vault, %{path: "a/Hub.md"})
    att = Fixtures.insert_attachment!(user, vault, %{path: "img/Pic.png"})

    :ok =
      Links.replace_links(user, vault, note.id, [
        %{target: "A/Hub", alias: nil, anchor: nil, link_type: "wikilink", position: 0}
      ])

    {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
    %{user: user, note: note, att: att, filter_key: filter_key}
  end

  defp strip_keys(user) do
    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.update_all(Note, set: [path_ci_hmac: nil, path_length: nil])
        Repo.update_all(Attachment, set: [path_ci_hmac: nil, path_length: nil])
        Repo.update_all(NoteLink, set: [target_key_hmac: nil])
      end)
  end

  defp row(user, schema, id) do
    {:ok, row} = Repo.with_tenant(user.id, fn -> Repo.get!(schema, id) end)
    row
  end

  test "fills every key, then the migration reports done", ctx do
    strip_keys(ctx.user)
    assert {:more, users: 1} = LinkResolutionKeys.run_pass()

    assert :ok = perform_job(BackfillLinkKeys, %{"user_id" => ctx.user.id})

    note = row(ctx.user, Note, ctx.note.id)

    assert [path_ci_hmac: note.path_ci_hmac, path_length: 8] ==
             Links.path_keys(ctx.filter_key, "a/Hub.md")

    att = row(ctx.user, Attachment, ctx.att.id)

    assert [path_ci_hmac: att.path_ci_hmac, path_length: att.path_length] ==
             Links.path_keys(ctx.filter_key, "img/Pic.png")

    {:ok, [edge]} = Repo.with_tenant(ctx.user.id, fn -> Repo.all(NoteLink) end)
    assert edge.target_key_hmac == Links.target_key_hmac(ctx.filter_key, "a/hub")

    assert LinkResolutionKeys.run_pass() == :done
  end

  test "a row whose ciphertext changed since it was read is left alone", ctx do
    strip_keys(ctx.user)

    # Another writer re-encrypted the path (a rename on an older node): the
    # stored ciphertext no longer matches what the key would be derived from.
    {:ok, _} =
      Repo.with_tenant(ctx.user.id, fn ->
        Repo.update_all(from(n in Note, where: n.id == ^ctx.note.id),
          set: [path_ciphertext: <<0::256>>]
        )
      end)

    ExUnit.CaptureLog.capture_log(fn ->
      assert :ok = perform_job(BackfillLinkKeys, %{"user_id" => ctx.user.id})
    end)

    assert row(ctx.user, Note, ctx.note.id).path_ci_hmac == nil
    # An undecryptable row keeps the migration open.
    assert {:more, users: 1} = LinkResolutionKeys.run_pass()
  end

  test "snoozes while the user's DEK rotation holds the lock", ctx do
    strip_keys(ctx.user)

    Repo.update_all(from(u in Engram.Accounts.User, where: u.id == ^ctx.user.id),
      set: [dek_rotation_locked_at: DateTime.utc_now()]
    )

    assert {:snooze, 60} = perform_job(BackfillLinkKeys, %{"user_id" => ctx.user.id})
  end
end
