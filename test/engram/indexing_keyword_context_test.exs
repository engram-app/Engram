defmodule Engram.IndexingKeywordContextTest do
  # The keyword (BM25) leg must index the same `context_text` the dense leg
  # embeds: title and heading path included (#1615). Since R3c the inputs are
  # the note's bytes only: the title is the frontmatter title or the first
  # H1, and neither the folder nor the file name is in them, so a rename
  # changes no vector. A note with no title is found by name through the
  # Postgres name leg instead.
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

  # Over 512 B: the chunker's min512 merge (v5) leaves each section alone,
  # so every section is still its own chunk.
  @pad String.duplicate("filler words here ", 30)

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

    # No H1: the title and folder exist only in the path, so (R3c) neither
    # reaches an input. Two sections of different lengths, so per-chunk
    # values cannot line up by accident.
    note =
      note!(user, vault, "Ops/Kubernetes Upgrade.md", """
      Drain each node before bumping the control plane. #{@pad}

      ## Rollback

      Restore the etcd snapshot first, then restart every kubelet in the pool one at a time. #{@pad} #{@pad}
      """)

    %{user: user, vault: vault, note: note}
  end

  defp note!(user, vault, path, content) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => content, "mtime" => 1.0},
        actor: "api"
      )

    {:ok, note} = Crypto.maybe_decrypt_note_fields(note, user)
    note
  end

  test "a full index encodes the heading path, never the folder or file name", ctx do
    {:ok, _} = Indexing.prepare_index(ctx.note, ctx.vault)

    assert_received {:encoded_texts, [_, _] = texts}
    refute Enum.any?(texts, &(&1 =~ "Kubernetes Upgrade" or &1 =~ "Ops")), inspect(texts)
    assert Enum.any?(texts, &(&1 =~ "Rollback" and &1 =~ "etcd"))
  end

  # The title the note's own bytes name still reaches every keyword input,
  # in a folder or not.
  for {label, head} <- [
        {"frontmatter title", "---\ntitle: Kubernetes Upgrade\n---\n"},
        {"H1", "# Kubernetes Upgrade\n\n"}
      ],
      path <- ["Ops/Runbook.md", "Runbook.md"] do
    test "a #{label} reaches every keyword input (#{path})", ctx do
      body = "Drain each node first. #{@pad}\n\n## Rollback\n\nRestore etcd. #{@pad}"
      note = note!(ctx.user, ctx.vault, unquote(path), unquote(head) <> body)
      {:ok, _} = Indexing.prepare_index(note, ctx.vault)

      assert_received {:encoded_texts, [_ | _] = texts}
      assert Enum.all?(texts, &(&1 =~ "Kubernetes Upgrade")), inspect(texts)
      refute Enum.any?(texts, &(&1 =~ "Ops" or &1 =~ "Runbook")), inspect(texts)
    end
  end

  test "a sparse-only re-index encodes what a full index does", ctx do
    %{vault: vault, user: user} = ctx
    note = note!(user, vault, "Ops/Runbook.md", "# Kubernetes Upgrade\n\nDrain each node first.")
    {:ok, _} = Indexing.index_note(note, vault, user)
    assert_received {:encoded_texts, indexed}

    assert {:ok, count, 0} = Indexing.resparse_note(note, user)
    assert count > 0

    assert_received {:encoded_texts, [_ | _] = texts}
    assert texts == indexed
    assert Enum.all?(texts, &(&1 =~ "Kubernetes Upgrade"))
    refute Enum.any?(texts, &(&1 =~ "Ops"))
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
