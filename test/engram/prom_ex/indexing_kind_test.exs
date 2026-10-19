defmodule Engram.PromEx.IndexingKindTest do
  @moduledoc """
  Embed less: `[:engram, :indexing, :points_written]` fires once per
  (kind, dense) pair per commit, counting only points actually written
  (reused points are excluded). Canvas and base notes are labelled by path
  although the chunker marks their chunks "data".
  """
  # Not async: telemetry handlers are global and the event carries no note id.
  use Engram.DataCase, async: false

  import Mox

  alias Engram.Crypto
  alias Engram.Indexing
  alias Engram.Notes
  alias Engram.PromEx.Indexing, as: IndexingPlugin
  alias Engram.ServiceConfig

  @event [:engram, :indexing, :points_written]

  @log_lines Enum.map_join(0..29, "\n", fn i ->
               "2026-10-19T05:14:#{String.pad_leading("#{i}", 2, "0")}.0863647Z id=zq98#{i} status=200"
             end)

  @content "---\nproject: zanzibar\n---\n# Plan\n\nThe first section talks about the launch.\n\n## Logs\n\n" <>
             @log_lines

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

    Bypass.stub(bypass, :any, :any, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true}))
    end)

    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)

    test_pid = self()
    id = "points-written-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      @event,
      fn _e, m, meta, _ -> send(test_pid, {:written, meta.kind, meta.dense, m.count}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
    %{user: user, vault: vault}
  end

  defp index(ctx, path, content) do
    {:ok, note} =
      Notes.upsert_note(
        ctx.user,
        ctx.vault,
        %{"path" => path, "content" => content, "mtime" => 1_000.0},
        actor: "api"
      )

    {:ok, note} = Crypto.maybe_decrypt_note_fields(note, ctx.user)
    {:ok, prepared} = Indexing.prepare_index(note, ctx.vault, ctx.user)
    {:ok, _} = Indexing.commit_index(prepared)
    note
  end

  defp drain do
    receive do
      {:written, kind, dense, count} -> [{kind, dense, count} | drain()]
    after
      0 -> []
    end
  end

  test "counts written points by kind and density", ctx do
    index(ctx, "Plan.md", @content)

    assert Enum.sort(drain()) ==
             [{"data", "false", 1}, {"frontmatter", "false", 1}, {"prose", "true", 1}]
  end

  test "canvas and base notes are labelled by path", ctx do
    index(ctx, "board.canvas", ~s({"nodes":[{"id":"a","type":"text","text":"hello world"}]}))
    assert [{"canvas", "false", n}] = drain()
    assert n >= 1

    index(ctx, "table.base", "filters:\n  and:\n    - file.hasTag(\"x\")\n")
    assert [{"base", "false", m}] = drain()
    assert m >= 1
  end

  test "reused points are not counted", ctx do
    note = index(ctx, "Plan.md", @content)
    drain()

    {:ok, prepared} = Indexing.prepare_index(note, ctx.vault, ctx.user)
    {:ok, _} = Indexing.commit_index(prepared)
    assert drain() == []
  end

  test "a commit that fails after the upsert counts nothing", ctx do
    {:ok, note} =
      Notes.upsert_note(
        ctx.user,
        ctx.vault,
        %{"path" => "Plan.md", "content" => @content, "mtime" => 1_000.0},
        actor: "api"
      )

    {:ok, note} = Crypto.maybe_decrypt_note_fields(note, ctx.user)
    {:ok, prepared} = Indexing.prepare_index(note, ctx.vault, ctx.user)

    # The points reach Qdrant, then the chunk-row transaction raises: the
    # retry will write them again, so this attempt must not count them.
    assert_raise RuntimeError, fn ->
      Indexing.commit_index(prepared, fn _ -> raise "chunk txn failed" end)
    end

    assert drain() == []
  end

  test "the counter is registered with closed-enum tags" do
    metric =
      [otp_app: :engram]
      |> IndexingPlugin.event_metrics()
      |> Map.fetch!(:metrics)
      |> Enum.find(&(&1.event_name == @event))

    assert metric.name == [:engram, :prom_ex, :indexing, :points_written, :total]
    assert metric.tags == [:kind, :dense]
  end
end
