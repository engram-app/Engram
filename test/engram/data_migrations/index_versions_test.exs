defmodule Engram.DataMigrations.IndexVersionsTest do
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Engram.DataMigrations
  alias Engram.DataMigrations.IndexVersions
  alias Engram.Indexing
  alias Engram.KeywordIndex
  alias Engram.Notes.Note
  alias Engram.Parsers.Markdown
  alias Engram.Workers.EmbedNote

  setup do
    DataMigrations.reset_cache()
    user = insert(:user)
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp set!(note, fields),
    do:
      Repo.update_all(from(n in Note, where: n.id == ^note.id), [set: fields],
        skip_tenant_check: true
      )

  defp current!(note) do
    set!(note,
      content_hash: "h",
      embed_hash: "h",
      dense_indexed_hash: "h",
      chunker_version: Markdown.chunker_version(),
      keyword_version: KeywordIndex.version(),
      embed_model: Indexing.embed_model()
    )
  end

  test "the name changes when a version changes" do
    assert IndexVersions.name() =~ "chunker=#{Markdown.chunker_version()}"
    assert IndexVersions.name() =~ "keyword=#{KeywordIndex.version()}"
  end

  test "the name carries the embed model, and \"none\" when there is none" do
    Application.put_env(:engram, :embed_model, "model-x")
    on_exit(fn -> Application.delete_env(:engram, :embed_model) end)
    assert IndexVersions.name() =~ ~r/,model=model-x$/

    # The test embedder declares no default model, so tracking is off.
    Application.delete_env(:engram, :embed_model)
    assert Indexing.embed_model() == nil
    assert IndexVersions.name() =~ ~r/,model=none$/
  end

  test "every note current: done", %{user: u, vault: v} do
    current!(insert(:note, user: u, vault: v))
    assert IndexVersions.run_pass() == :done
  end

  test "a content-current note on an old chunker keeps it open", %{user: u, vault: v} do
    note = insert(:note, user: u, vault: v)
    current!(note)
    set!(note, chunker_version: Markdown.chunker_version() - 1)
    assert IndexVersions.run_pass() == :more
  end

  test "a content-current note on an old keyword version keeps it open", %{user: u, vault: v} do
    note = insert(:note, user: u, vault: v)
    current!(note)
    set!(note, keyword_version: nil)
    assert IndexVersions.run_pass() == :more
  end

  test "a note waiting for its first embed does not keep it open", %{user: u, vault: v} do
    note = insert(:note, user: u, vault: v)
    set!(note, content_hash: "new", embed_hash: nil, chunker_version: nil, keyword_version: nil)
    assert IndexVersions.run_pass() == :done
  end

  test "a deleted note does not keep it open", %{user: u, vault: v} do
    note = insert(:note, user: u, vault: v)
    current!(note)
    set!(note, chunker_version: 0, deleted_at: DateTime.utc_now(:second))
    assert IndexVersions.run_pass() == :done
  end

  # Restoring the vault is healed by ReconcileEmbeddings' daily re-verify,
  # not by holding this open.
  test "a stale note in a soft-deleted vault does not keep it open", %{user: u, vault: v} do
    note = insert(:note, user: u, vault: v)
    current!(note)
    set!(note, chunker_version: 0)

    Repo.update_all(
      from(x in Engram.Vaults.Vault, where: x.id == ^v.id),
      [set: [deleted_at: DateTime.utc_now(:second)]],
      skip_tenant_check: true
    )

    assert IndexVersions.run_pass() == :done
  end

  # Rollout review F3: rolling back to an older release must not treat every
  # note a newer release stamped as stale, or each rollback re-indexes all.
  describe "a version stamped by a newer release" do
    defp selected(dynamic),
      do: Repo.all(from(n in Note, where: ^dynamic, select: n.id), skip_tenant_check: true)

    test "a newer chunker counts as current, an older one as stale", %{user: u, vault: v} do
      newer = insert(:note, user: u, vault: v)
      older = insert(:note, user: u, vault: v)
      current!(newer)
      current!(older)
      set!(newer, chunker_version: Markdown.chunker_version() + 1)
      set!(older, chunker_version: Markdown.chunker_version() - 1)

      assert selected(IndexVersions.stale_dynamic()) == [older.id]
    end

    test "a newer keyword version counts as current, an older one as stale", %{user: u, vault: v} do
      newer = insert(:note, user: u, vault: v)
      older = insert(:note, user: u, vault: v)
      current!(newer)
      current!(older)
      set!(newer, keyword_version: KeywordIndex.version() + 1)
      set!(older, keyword_version: KeywordIndex.version() - 1)

      assert selected(IndexVersions.keyword_stale_dynamic()) == [older.id]
    end

    test "every note newer than this build: done", %{user: u, vault: v} do
      note = insert(:note, user: u, vault: v)
      current!(note)

      set!(note,
        chunker_version: Markdown.chunker_version() + 1,
        keyword_version: KeywordIndex.version() + 1
      )

      assert IndexVersions.run_pass() == :done
    end

    test "EmbedNote.version_stale?/1 agrees" do
      stale? = &EmbedNote.version_stale?(%Note{chunker_version: &1})
      refute stale?.(Markdown.chunker_version() + 1)
      refute stale?.(Markdown.chunker_version())
      assert stale?.(Markdown.chunker_version() - 1)
      assert stale?.(nil)
    end
  end
end
