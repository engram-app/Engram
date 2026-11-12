defmodule Engram.DataMigrations.NoteMetaTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query
  import Engram.RlsCase

  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.DataMigrations.NoteMeta
  alias Engram.Fixtures
  alias Engram.Links.NoteLink
  alias Engram.Notes
  alias Engram.Notes.{Helpers, Note}
  alias Engram.Workers.{DataMigrationsRunner, RebuildStaleNote}

  # A `---foo` close: the old rules closed the frontmatter there, the shared
  # fence rule (#2564) does not, so title and tags read differently.
  @content "---\ntags: [old]\n---foo\n# Heading\n\nsee [[Other]] #inline\n"

  setup do
    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user, is_default: true)
    %{user: user, vault: vault}
  end

  defp derived(content, path \\ "n.md"), do: Helpers.extract_title_and_tags(content, path)

  defp upsert!(ctx, path, content) do
    {:ok, note} =
      Notes.upsert_note(ctx.user, ctx.vault, %{"path" => path, "content" => content},
        actor: "api"
      )

    Repo.delete_all(from(l in NoteLink, where: l.source_note_id == ^note.id),
      skip_tenant_check: true
    )

    note
  end

  # A note stored under older rules: its title and tags are not what the
  # current rules derive (written bound to the row, as a writer would), and
  # its links were never extracted.
  defp stale_note(ctx, path \\ "n.md") do
    note = upsert!(ctx, path, @content)
    {:ok, dek} = Crypto.get_dek(ctx.user)

    {title_ct, title_n} =
      Envelope.encrypt("old title", dek, Crypto.aad_for_row(:notes, :title, note.id))

    {tags_ct, tags_n} =
      Envelope.encrypt(
        :erlang.term_to_binary(["old"]),
        dek,
        Crypto.aad_for_row(:notes, :tags, note.id)
      )

    Fixtures.write_note_body!(note.id,
      title_ciphertext: title_ct,
      title_nonce: title_n,
      tags_ciphertext: tags_ct,
      tags_nonce: tags_n
    )

    note
  end

  # A note already right under the current rules (no links to extract).
  defp current_note(ctx, content), do: upsert!(ctx, "c.md", content)

  defp decrypted(note, user) do
    {:ok, n} = Crypto.maybe_decrypt_note_fields(Fixtures.raw_note!(note.id), user)
    n
  end

  defp links(note),
    do:
      Repo.all(from(l in NoteLink, where: l.source_note_id == ^note.id), skip_tenant_check: true)

  defp run_until_done(n \\ 5) do
    Enum.reduce_while(1..n, nil, fn _, _ ->
      case NoteMeta.run_pass(batch: 50) do
        :done -> {:halt, :done}
        more -> {:cont, more}
      end
    end)
  end

  test "a note stored under the old rules gets the current title, tags and links", ctx do
    note = stale_note(ctx)
    {title, tags} = derived(@content)
    # Precondition: the fixture really is stale, or the asserts below prove nothing.
    assert decrypted(note, ctx.user).title == "old title"
    assert title != "old title"
    assert links(note) == []

    assert {:more, rows: 1} = NoteMeta.run_pass(batch: 50)

    healed = decrypted(note, ctx.user)
    assert {healed.title, healed.tags} == {title, tags}
    assert healed.meta_version == Helpers.meta_version()
    assert [%NoteLink{}] = links(note)
    assert_enqueued(worker: RebuildStaleNote, args: %{note_id: note.id, key_aliases: true})

    # The next walk rewrites nothing and closes.
    assert :done = NoteMeta.run_pass(batch: 50)
  end

  test "an up-to-date note is stamped only: no rewrite, no re-embed", ctx do
    note = current_note(ctx, "---\ntags: [a]\n---\n# Fine\n\nbody #b\n")
    before = Fixtures.raw_note!(note.id)

    assert :done = run_until_done()

    after_ = Fixtures.raw_note!(note.id)
    assert after_.meta_version == Helpers.meta_version()

    for f <- [
          :title_ciphertext,
          :tags_ciphertext,
          :tags_hmac,
          :version,
          :seq,
          :updated_at,
          :embed_hash
        ],
        do: assert(Map.get(after_, f) == Map.get(before, f), "#{f} moved")

    refute_enqueued(worker: RebuildStaleNote)
  end

  test "a note already stamped with the current rules is not read again", ctx do
    note = stale_note(ctx)

    Repo.update_all(
      from(n in Note, where: n.id == ^note.id),
      [set: [meta_version: Helpers.meta_version()]],
      skip_tenant_check: true
    )

    assert :done = NoteMeta.run_pass(batch: 50)
    assert decrypted(note, ctx.user).title == "old title"
    refute_enqueued(worker: RebuildStaleNote)
  end

  test "kill switch off (the default): the runner does no work", ctx do
    note = stale_note(ctx)
    refute NoteMeta.enabled?()

    assert :ok = perform_job(DataMigrationsRunner, %{})

    row = decrypted(note, ctx.user)
    assert row.title == "old title"
    assert is_nil(row.meta_version)
    assert links(note) == []
  end

  test "registered with the runner, off until the override turns it on" do
    assert NoteMeta in DataMigrationsRunner.migrations()
    refute NoteMeta.enabled?()
    Engram.ServiceConfig.put_override(:note_meta_backfill, true)
    assert NoteMeta.enabled?()
  end

  test "a pass is bounded: it stops after max_fixed rewrites and resumes", ctx do
    notes = for i <- 1..3, do: stale_note(ctx, "n#{i}.md")
    stamped = fn -> Enum.count(notes, &(decrypted(&1, ctx.user).meta_version != nil)) end

    assert {:more, rows: 1} = NoteMeta.run_pass(batch: 1, max_fixed: 1)
    assert stamped.() == 1
    assert {:more, rows: 1} = NoteMeta.run_pass(batch: 1, max_fixed: 1)
    assert stamped.() == 2
  end

  describe "tenant scoping" do
    test "control: in another tenant's context the heal reads and writes nothing", ctx do
      note = stale_note(ctx)
      other = insert(:user)

      assert {0, false} =
               as_prod_role_committing(fn ->
                 NoteMeta.heal_window([note.id], %{repo: Repo, user_id: other.id})
               end)

      row = decrypted(note, ctx.user)
      assert row.title == "old title"
      assert is_nil(row.meta_version)
    end

    test "in the owner's tenant the heal rewrites the row", ctx do
      note = stale_note(ctx)

      assert {1, false} =
               as_prod_role_committing(fn ->
                 NoteMeta.heal_window([note.id], %{repo: Repo, user_id: ctx.user.id})
               end)

      assert decrypted(note, ctx.user).title == elem(derived(@content), 0)
    end
  end
end
