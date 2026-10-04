defmodule Engram.IndexingKeywordContextTest do
  # The keyword (BM25) leg must index the same `context_text` the dense leg
  # embeds: folder, title and heading path included. A note with no H1 (the
  # Obsidian default) otherwise has no token for its own title, so keyword-only
  # search cannot find it by name (#1615).
  #
  # async: false — swaps the global :keyword_index adapter via Application env.
  use Engram.DataCase, async: false

  import Mox

  alias Engram.Crypto
  alias Engram.Indexing
  alias Engram.Notes
  alias Engram.Notes.Chunk

  defmodule RecordingKeywordIndex do
    @moduledoc false
    @behaviour Engram.KeywordIndex

    alias Engram.KeywordIndex.QdrantSparse

    @impl true
    def encode_documents(texts, filter_key, avgdl, language) do
      send(self(), {:encoded_texts, texts})
      QdrantSparse.encode_documents(texts, filter_key, avgdl, language)
    end

    @impl true
    def encode_query(query, filter_key, language),
      do: QdrantSparse.encode_query(query, filter_key, language)
  end

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    bypass = Bypass.open()
    Engram.ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

    Bypass.stub(bypass, :any, :any, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true, "status": "ok"}))
    end)

    Application.put_env(:engram, :keyword_index, RecordingKeywordIndex)
    on_exit(fn -> Application.delete_env(:engram, :keyword_index) end)

    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)

    # No H1: the title and folder exist only in the path. Two sections of
    # different lengths, so per-chunk values cannot line up by accident.
    note =
      note!(user, vault, "Ops/Kubernetes Upgrade.md", """
      Drain each node before bumping the control plane.

      ## Rollback

      Restore the etcd snapshot first, then restart every kubelet in the pool one at a time.
      """)

    %{user: user, vault: vault, note: note}
  end

  defp note!(user, vault, path, content) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => content, "mtime" => 1.0})

    {:ok, note} = Crypto.maybe_decrypt_note_fields(note, user)
    note
  end

  test "a full index encodes folder, title and heading into the keyword leg", ctx do
    {:ok, _} = Indexing.prepare_index(ctx.note, ctx.vault)

    assert_received {:encoded_texts, [_, _] = texts}
    assert Enum.all?(texts, &(&1 =~ "Kubernetes Upgrade" and &1 =~ "Ops"))
    assert Enum.any?(texts, &(&1 =~ "Rollback" and &1 =~ "etcd"))
  end

  test "a note in the vault root still carries its title", ctx do
    note = note!(ctx.user, ctx.vault, "Kubernetes Upgrade.md", "Drain each node first.")
    {:ok, _} = Indexing.prepare_index(note, ctx.vault)

    assert_received {:encoded_texts, [text]}
    assert text =~ "Kubernetes Upgrade"
  end

  test "a sparse-only re-index encodes folder and title too", ctx do
    %{note: note, vault: vault, user: user} = ctx
    {:ok, _} = Indexing.index_note(note, vault, user)
    assert_received {:encoded_texts, _}

    assert {:ok, count, 0} = Indexing.resparse_note(note, user)
    assert count > 0

    assert_received {:encoded_texts, [_ | _] = texts}
    assert Enum.all?(texts, &(&1 =~ "Kubernetes Upgrade" and &1 =~ "Ops"))
  end

  # `chunks.token_count` is the only input to the vault's `avgdl`. A resparse
  # that rewrites the vectors but not the lengths leaves BM25 normalizing
  # against lengths of a string it no longer encodes.
  test "a sparse-only re-index persists the new token_count", ctx do
    %{note: note, vault: vault, user: user} = ctx
    {:ok, _} = Indexing.index_note(note, vault, user)
    indexed = token_counts(note)
    assert [short, long] = indexed
    assert short > 1 and long > short

    # A row written by the old text-only encoding.
    {:ok, _} =
      Repo.with_tenant(note.user_id, fn ->
        Repo.update_all(from(c in Chunk, where: c.note_id == ^note.id), set: [token_count: 1])
      end)

    assert {:ok, _, 0} = Indexing.resparse_note(note, user)
    assert token_counts(note) == indexed
  end

  defp token_counts(note) do
    {:ok, counts} =
      Repo.with_tenant(note.user_id, fn ->
        Repo.all(
          from(c in Chunk,
            where: c.note_id == ^note.id,
            order_by: c.position,
            select: c.token_count
          )
        )
      end)

    counts
  end
end
