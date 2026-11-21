defmodule Engram.IndexingFrontmatterOnceTest do
  @moduledoc """
  An index pass parses a note's frontmatter once and hands that parse to both
  readers of it: the OKF timestamp heal and the `note_attrs` filter fields
  (`FlatFields`). Each used to split and parse the block again. The filter
  fields and dates a pass produces must be exactly what `FlatFields.extract/2`
  gives for the same text.
  """
  use Engram.DataCase, async: true

  import Mox

  alias Engram.Crypto
  alias Engram.Indexing
  alias Engram.Notes
  alias Engram.Notes.{FlatFields, FrontmatterKeys}
  alias Engram.ServiceConfig

  setup :verify_on_exit!

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
    %{user: user, vault: insert(:vault, user: user)}
  end

  @notes %{
    "plain.md" => "# No frontmatter\n\nJust a body.\n",
    "simple.md" =>
      "---\nstatus: draft\nauthor: Ada\nupdated: 2026-01-02\ntags: [a, b]\n---\n# Body\n",
    "crlf.md" =>
      "---\r\nstatus: done\r\nproject: Apollo\r\ncreated: 2025-12-31\r\n---\r\nBody\r\n",
    "odd.md" => """
    ---
    base: &b
      x: 1
    copy: *b
    "quoted key": "a: b"
    種類: memo
    priority: 2.5
    source:
      - one
      - two
    due: 2026-03-04
    multi: |
      line one
      line two
    ---
    Body with [[link]]
    """,
    "only.md" => "---\nstatus: frontmatter only\n---\n",
    "okf.md" => "---\ngenerated:\n  at: 2026-02-03T04:05:06Z\nstatus: x\n---\nBody\n"
  }

  for {path, content} <- @notes do
    test "#{path}: the pass's filter fields equal FlatFields.extract/2", ctx do
      {:ok, note} =
        Notes.upsert_note(
          ctx.user,
          ctx.vault,
          %{"path" => unquote(path), "content" => unquote(content)},
          actor: "api"
        )

      {:ok, note} = Crypto.maybe_decrypt_note_fields(note, ctx.user)
      # A row saved before the OKF timestamp was read: the pass heals it.
      note = %{note | fm_timestamp: nil}

      assert {:ok, prepared} = Indexing.prepare_index(note, ctx.vault, ctx.user)

      {:ok, dek} = Crypto.get_dek(ctx.user)
      flat = FlatFields.extract(note.content, Crypto.dek_filter_key_from_bytes(dek))
      {ids, _} = FrontmatterKeys.resolve(note.user_id, dek, flat.names)
      flat = FlatFields.put_key_ids(flat, ids)

      assert prepared.attr_rows == FlatFields.attr_rows(flat, prepared.note)
      assert prepared.fm_dates == %{fm_updated: flat.fm_updated, fm_created_s: flat.fm_created}
      assert prepared.okf_healed? == (unquote(path) == "okf.md")
    end
  end
end
