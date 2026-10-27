defmodule Engram.NotePointsCapFlagTest do
  @moduledoc """
  The per-note cap merge. The v5 pass prices and writes every over-cap note
  capped, so each note is embedded once and the 04:00 tick must not embed a
  capped note again.

  async: false: global Mox mode and `limits_enforced` are global app env.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Mox

  alias Engram.Crypto
  alias Engram.Indexing
  alias Engram.KeywordIndex
  alias Engram.Notes.Chunk
  alias Engram.Notes.Note
  alias Engram.Parsers.Markdown
  alias Engram.Rebuild
  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant
  alias Engram.Workers.{EmbedNote, RebuildStaleNote, ReconcileEmbeddings}

  setup :set_mox_global
  setup :verify_on_exit!

  @pins {Markdown.chunker_version() - 1, KeywordIndex.version() - 1}
  @green %{"status" => "green", "optimizer_status" => "ok", "update_queue" => %{"length" => 0}}
  @pad String.duplicate("filler words here ", 30)

  setup do
    Engram.Cache.clear_local(:rebuild)
    Repo.query!("DELETE FROM rebuild_ledger")
    EngramWeb.RateLimiter.reset_buckets!()
    ServiceConfig.put_override(:rebuild_pinned_versions, @pins)
    Rebuild.set_budget(10_000_000)

    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    col = "/collections/#{Qdrant.collection_name()}"

    Bypass.stub(bypass, :any, :any, fn conn ->
      body =
        case {conn.method, conn.request_path} do
          {"GET", ^col} ->
            %{"result" => @green, "status" => "ok"}

          {"GET", path} when path == col <> "/optimizations" ->
            summary = %{
              "queued_optimizations" => 0,
              "queued_segments" => 0,
              "queued_points" => 0,
              "idle_segments" => 1
            }

            %{"result" => %{"summary" => summary, "running" => []}, "status" => "ok"}

          _ ->
            %{"result" => true, "status" => "ok"}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end)

    parent = self()

    embed = fn texts ->
      send(parent, {:embedded, length(texts)})
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end

    stub(Engram.MockEmbedder, :embed_texts, embed)
    stub(Engram.MockEmbedder, :embed_texts, fn texts, _opts -> embed.(texts) end)

    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user, is_default: true)
    %{user: user, vault: vault}
  end

  defp sections(n),
    do:
      "# Big\n\n" <>
        Enum.map_join(1..n, "\n\n", &"## S#{&1}\n\nsection#{&1} body text. #{@pad}")

  # A note indexed while no cap applied (limits unenforced): over the cap, as
  # one left by a downgrade or a lowered override is.
  defp index_uncapped(note) do
    Application.put_env(:engram, :limits_enforced, false)

    try do
      assert :ok = perform_job(EmbedNote, %{"note_id" => note.id, "user_id" => note.user_id})
    after
      Application.put_env(:engram, :limits_enforced, true)
    end
  end

  defp reverify_tick, do: DateTime.new!(Date.utc_today(), ~T[04:02:00])

  defp insert_note(user, vault, content) do
    note = Engram.Fixtures.insert_note!(user, vault, %{path: "Big.md", content: content})
    {:ok, note} = Crypto.maybe_decrypt_note_fields(note, user)
    note
  end

  # As prod before the pass: indexed long ago (no rows needed), stamped with
  # the pre-v5 pins.
  defp stamp_pinned(note) do
    Repo.with_tenant!(note.user_id, fn ->
      Repo.update_all(from(n in Note, where: n.id == ^note.id),
        set: [
          embed_hash: note.content_hash,
          dense_indexed_hash: note.content_hash,
          chunker_version: elem(@pins, 0),
          keyword_version: elem(@pins, 1),
          embed_retry_after: nil
        ]
      )
    end)

    Repo.delete_all(from(j in Oban.Job, where: fragment("?->>'note_id'", j.args) == ^note.id))
    note
  end

  defp rows(note),
    do:
      Repo.with_tenant!(note.user_id, fn ->
        Repo.aggregate(from(c in Chunk, where: c.note_id == ^note.id), :count)
      end)

  defp embedded(n \\ 0) do
    receive do
      {:embedded, k} -> embedded(n + k)
    after
      0 -> n
    end
  end

  defp reserved(n \\ 0) do
    receive do
      {:reserved, k} -> reserved(n + k)
    after
      0 -> n
    end
  end

  defp lapse_cooldown(note) do
    Repo.with_tenant!(note.user_id, fn ->
      Repo.update_all(from(n in Note, where: n.id == ^note.id),
        set: [embed_retry_after: DateTime.add(DateTime.utc_now(), -1, :second)]
      )
    end)
  end

  defp no_job_for(note) do
    refute_enqueued(worker: RebuildStaleNote, args: %{"note_id" => note.id})
    refute_enqueued(worker: EmbedNote, args: %{"note_id" => note.id})
  end

  defp reindex(note, vault, user) do
    {:ok, note} =
      Repo.with_tenant!(user.id, fn -> Repo.get!(Note, note.id) end)
      |> Crypto.maybe_decrypt_note_fields(user)

    assert {:ok, _} =
             Indexing.index_note(note, vault, Repo.reload!(user, skip_tenant_check: true))
  end

  describe "per-note cap" do
    test "an edit caps a Free note to 128 points", %{user: user, vault: vault} do
      note = insert_note(user, vault, sections(500))
      assert {:ok, n, _, true} = Indexing.index_note_with_usage(note, vault, user)
      assert n <= 128 and rows(note) == n
      assert embedded() == n
    end

    # Adversarial V3 with the cap alone: the merge is our storage decision, so
    # an edit inside a merged group charges the user the changed chunk only,
    # not the whole group (up to 30 KB of a Free embed bucket per edit).
    test "an edit inside a merged group charges the changed chunk", %{user: user, vault: vault} do
      parent = self()
      opts = [reserve_tokens: &(send(parent, {:reserved, &1}) && true)]
      note = insert_note(user, vault, sections(500))
      assert {:ok, _, _, true} = Indexing.index_note_with_usage(note, vault, user, opts)
      _ = {embedded(), reserved()}

      edited = String.replace(note.content, "section250 body", "section250 edited body")

      assert {:ok, _, _, true} =
               Indexing.index_note_with_usage(%{note | content: edited}, vault, user, opts)

      [changed] =
        edited |> Markdown.parse("Big.md") |> Enum.filter(&String.contains?(&1.text, "edited"))

      assert reserved() == Engram.UsageMeters.estimate_tokens(byte_size(changed.embed_text))
    end

    test "the dry-run estimate prices the capped note", %{user: user, vault: vault} do
      note = insert_note(user, vault, sections(500))
      {:ok, est} = Repo.with_tenant!(user.id, fn -> Indexing.rebuild_estimate(note, user) end)
      assert est.new_points + est.reused_points <= 128
    end

    test "the v5 pass embeds an over-cap note once, capped, and nothing re-embeds it",
         %{user: user, vault: vault} do
      ServiceConfig.put_override(:index_rebuild, "on")
      note = user |> insert_note(vault, sections(500)) |> stamp_pinned()

      assert :ok = perform_job(RebuildStaleNote, %{"note_id" => note.id, "user_id" => user.id})
      once = embedded()
      assert once > 0 and once <= 128
      assert rows(note) == once

      # The 04:00 tick (recap included), a second rebuild job and an
      # edit-less index pass: none of them pays again.
      lapse_cooldown(note)
      assert :ok = perform_job(ReconcileEmbeddings, %{}, scheduled_at: reverify_tick())
      no_job_for(note)
      assert :ok = perform_job(RebuildStaleNote, %{"note_id" => note.id, "user_id" => user.id})
      reindex(note, vault, user)
      assert embedded() == 0

      # The same on the next tick.
      lapse_cooldown(note)
      assert :ok = perform_job(ReconcileEmbeddings, %{}, scheduled_at: reverify_tick())
      no_job_for(note)
      assert :ok = perform_job(EmbedNote, %{"note_id" => note.id, "user_id" => user.id})
      reindex(note, vault, user)
      assert embedded() == 0
      assert rows(note) == once
    end

    # The pass rebuilds it: a recap now would pay for it a second time.
    test "the recap leaves an over-cap note the pass will rebuild alone",
         %{user: user, vault: vault} do
      ServiceConfig.put_override(:index_rebuild, "dry_run")
      note = insert_note(user, vault, sections(500))
      index_uncapped(note)
      assert rows(note) == 500
      stamp_pinned(note)

      assert :ok = perform_job(ReconcileEmbeddings, %{}, scheduled_at: reverify_tick())
      refute_enqueued(worker: RebuildStaleNote, args: %{"note_id" => note.id, "recap" => true})
    end

    # After the pass (every note at the build), the recap caps a note still
    # over it, e.g. after a downgrade.
    test "the recap still caps a build-current note over the cap", %{user: user, vault: vault} do
      ServiceConfig.put_override(:rebuild_pinned_versions, Rebuild.build_versions())
      note = insert_note(user, vault, sections(500))
      index_uncapped(note)
      assert rows(note) == 500
      lapse_cooldown(note)

      assert :ok = perform_job(ReconcileEmbeddings, %{}, scheduled_at: reverify_tick())
      assert_enqueued(worker: RebuildStaleNote, args: %{"note_id" => note.id, "recap" => true})
    end
  end
end
