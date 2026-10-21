defmodule Engram.RebuildLedgerWiringTest do
  @moduledoc """
  The v5 rebuild ledger on the real worker path (`RebuildStaleNote`, which
  runs `EmbedNote`'s version-rebuild route): a halt stops queued rebuilds
  before Voyage, the ledger is debited what Voyage reported, and a note
  that drifts past its estimate is parked.

  async: false: global Mox mode and the reconcile/Oban state.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Mox

  alias Engram.Crypto
  alias Engram.KeywordIndex
  alias Engram.Notes
  alias Engram.Notes.Note
  alias Engram.Parsers.Markdown
  alias Engram.Rebuild
  alias Engram.ServiceConfig
  alias Engram.Workers.{EmbedNote, RebuildStaleNote}

  setup :set_mox_global
  setup :verify_on_exit!

  # Build at chunker 3 / keyword 2, pins at 2 / 1: a note stamped 2 is the
  # pass's to rebuild only while the switch is `on`.
  @pins {Markdown.chunker_version() - 1, KeywordIndex.version() - 1}

  setup do
    Engram.Cache.clear_local(:rebuild)
    Repo.query!("DELETE FROM rebuild_ledger")
    ServiceConfig.put_override(:rebuild_pinned_versions, @pins)
    ServiceConfig.put_override(:index_rebuild, "on")

    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

    Bypass.stub(bypass, :any, :any, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true, "status": "ok"}))
    end)

    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)

    # Content current and dense, never chunked: the rebuild embeds it all.
    {:ok, note} =
      Notes.upsert_note(
        user,
        vault,
        %{"path" => "A.md", "content" => "# Alpha\n\nalpha words here", "mtime" => 1.0},
        actor: "api"
      )

    Repo.with_tenant!(user.id, fn ->
      Repo.update_all(from(n in Note, where: n.id == ^note.id),
        set: [
          embed_hash: note.content_hash,
          dense_indexed_hash: note.content_hash,
          chunker_version: elem(@pins, 0),
          keyword_version: elem(@pins, 1)
        ]
      )
    end)

    %{user: user, vault: vault, note: note}
  end

  # A Voyage stand-in that reports `tokens` the way the real client does.
  defp embedder_reporting(tokens) do
    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      :telemetry.execute(
        [:engram, :voyage, :embed, :tokens],
        %{total_tokens: tokens},
        %{purpose: :index}
      )

      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)
  end

  defp rebuild(note),
    do: perform_job(RebuildStaleNote, %{"note_id" => note.id, "user_id" => note.user_id})

  defp reload(note), do: Repo.with_tenant!(note.user_id, fn -> Repo.get!(Note, note.id) end)

  test "the ledger is debited exactly what Voyage reported", %{note: note} do
    Rebuild.set_budget(10_000)
    embedder_reporting(123)

    assert :ok = rebuild(note)
    assert Rebuild.ledger().spent_tokens == 123
  end

  test "a job queued before a halt makes 0 Voyage calls", %{note: note} do
    Rebuild.set_budget(1)
    assert Rebuild.debit(2) == :halt
    expect(Engram.MockEmbedder, :embed_texts, 0, fn _ -> flunk("Voyage called after halt") end)

    assert :ok = rebuild(note)
    assert Rebuild.ledger().spent_tokens == 2
    # Not rebuilt: still behind the build, waiting for `on`.
    assert reload(note).chunker_version == elem(@pins, 0)
  end

  test "a debit past the budget halts, so the next queued job makes 0 calls", ctx do
    %{note: note, user: user, vault: vault} = ctx
    Rebuild.set_budget(100)
    embedder_reporting(500)
    assert :ok = rebuild(note)
    assert Rebuild.mode() == :off

    {:ok, other} =
      Notes.upsert_note(
        user,
        vault,
        %{"path" => "B.md", "content" => "# Beta\n\nbeta words", "mtime" => 1.0},
        actor: "api"
      )

    Repo.with_tenant!(user.id, fn ->
      Repo.update_all(from(n in Note, where: n.id == ^other.id),
        set: [
          embed_hash: other.content_hash,
          dense_indexed_hash: other.content_hash,
          chunker_version: elem(@pins, 0)
        ]
      )
    end)

    expect(Engram.MockEmbedder, :embed_texts, 0, fn _ -> flunk("Voyage called after halt") end)
    assert :ok = rebuild(other)
  end

  test "a note that drifts past 1.5x its estimate and 50k tokens is parked", ctx do
    %{note: note, user: user, vault: vault} = ctx
    Rebuild.set_budget(1_000_000)

    :ok =
      Rebuild.put_manifest(user.id, [
        %{
          note_id: note.id,
          vault_id: vault.id,
          est_tokens: 10,
          new_points: 1,
          reused_points: 0,
          mean_pooled_points: 0,
          dl_sum: 3,
          dl_count: 1
        }
      ])

    ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :rebuild, :drift_parked]])
    embedder_reporting(60_000)

    assert :ok = rebuild(note)
    assert_received {[:engram, :rebuild, :drift_parked], ^ref, %{tokens: 60_000}, _}
    assert reload(note).embed_retry_after == EmbedNote.parked_until_edited()
  end

  test "with the switch off the job rebuilds nothing and spends nothing", %{note: note} do
    ServiceConfig.put_override(:index_rebuild, "off")
    expect(Engram.MockEmbedder, :embed_texts, 0, fn _ -> flunk("Voyage called while off") end)

    assert :ok = rebuild(note)
    assert Rebuild.ledger() == nil
  end
end
