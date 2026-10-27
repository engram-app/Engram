defmodule Engram.PromEx.IndexingChunksTest do
  @moduledoc """
  `[:engram, :indexing, :chunks]` fires per outcome (`embedded | reused`) once
  per committed pass, and an indexing pass labels its Voyage calls with the
  owner's tier and the job's trigger.
  """
  # Not async: telemetry handlers are global and the event carries no note id.
  use Engram.DataCase, async: false

  import Mox

  alias Engram.Crypto
  alias Engram.Embedders.UsageLabels
  alias Engram.Indexing
  alias Engram.Notes
  alias Engram.PromEx.Indexing, as: IndexingPlugin
  alias Engram.ServiceConfig
  alias Engram.Test.PromExMetrics
  alias Engram.Workers.EmbedNote

  @event [:engram, :indexing, :chunks]
  @content "# Plan\n\nThe first section talks about the launch.\n\n## Logs\n\nSecond section body text."

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

    Bypass.stub(bypass, :any, :any, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true}))
    end)

    test_pid = self()

    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      send(test_pid, {:labels, UsageLabels.current()})
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)

    id = "chunks-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      @event,
      fn _e, m, meta, _ -> send(test_pid, {:chunks, meta.outcome, m.count}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
    %{user: user, vault: vault}
  end

  defp note_for(ctx, content) do
    {:ok, note} =
      Notes.upsert_note(
        ctx.user,
        ctx.vault,
        %{"path" => "Plan.md", "content" => content, "mtime" => 1_000.0},
        actor: "api"
      )

    {:ok, note} = Crypto.maybe_decrypt_note_fields(note, ctx.user)
    note
  end

  defp drain do
    receive do
      {:chunks, outcome, count} -> [{outcome, count} | drain()]
    after
      0 -> []
    end
  end

  test "a first pass embeds every chunk; an unchanged re-index reuses them", ctx do
    note = note_for(ctx, @content)
    assert {:ok, n, _, _} = Indexing.index_note_with_usage(note, ctx.vault, ctx.user, [])
    assert drain() == [embedded: n]

    assert {:ok, ^n, _, _} = Indexing.index_note_with_usage(note, ctx.vault, ctx.user, [])
    assert drain() == [reused: n]
  end

  test "the pass labels Voyage calls with the owner's tier and the job's trigger", ctx do
    note = note_for(ctx, @content)

    {:ok, _, _, _} =
      Indexing.index_note_with_usage(note, ctx.vault, ctx.user, embed_trigger: :upgrade)

    assert_received {:labels, %{tier: :free, trigger: :upgrade}}

    # No trigger given (a direct caller): an edit.
    other = note_for(ctx, @content <> "\n\nMore.")
    {:ok, _, _, _} = Indexing.index_note_with_usage(other, ctx.vault, ctx.user, [])
    assert_received {:labels, %{trigger: :edit}}

    # Labels do not leak past the pass.
    assert UsageLabels.current() == %{tier: :none, trigger: :none}
  end

  test "a paid owner's pass is labelled tier :paid", ctx do
    insert(:subscription, user: ctx.user, tier: "pro", status: "active")
    user = Engram.Accounts.get_user_with_subscription!(ctx.user.id)
    note = note_for(ctx, @content)

    {:ok, _, _, _} = Indexing.index_note_with_usage(note, ctx.vault, user, [])
    assert_received {:labels, %{tier: :paid}}
  end

  test "embed_trigger/1 maps a job to the closed enum" do
    job = fn attrs ->
      struct(Oban.Job, Map.merge(%{worker: "Engram.Workers.EmbedNote"}, attrs))
    end

    assert EmbedNote.embed_trigger(job.(%{attempt: 1, priority: 0})) == :edit
    assert EmbedNote.embed_trigger(job.(%{attempt: 2, priority: 0})) == :retry

    assert EmbedNote.embed_trigger(job.(%{attempt: 1, priority: EmbedNote.backfill_priority()})) ==
             :reconcile

    rebuild = %{worker: "Engram.Workers.RebuildStaleNote", attempt: 1, priority: 0}
    assert EmbedNote.embed_trigger(job.(Map.put(rebuild, :args, %{}))) == :rebuild

    assert EmbedNote.embed_trigger(job.(Map.put(rebuild, :args, %{"upgrade" => true}))) ==
             :upgrade
  end

  test "the counter is registered with the closed outcome tag" do
    metric =
      [otp_app: :engram]
      |> then(&PromExMetrics.of(IndexingPlugin, &1))
      |> Map.fetch!(:metrics)
      |> Enum.find(&(&1.event_name == @event))

    assert metric.name == [:engram, :prom_ex, :indexing, :chunks, :total]
    assert metric.tags == [:outcome]
  end
end
