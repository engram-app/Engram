defmodule Engram.IndexingPathFreeReuseTest do
  @moduledoc """
  R3c: a chunk's inputs are the note's bytes only, so the reuse fingerprint
  no longer moves with the path.

  The next-edit half of the hard invariant (Engram#2523): after a note
  rename, a note move, a folder rename or a folder move, the note's next
  one-chunk edit embeds that one chunk and writes one point; every other
  chunk keeps its point. Counted at the shared clients: every Qdrant HTTP
  request hits the Bypass at `:qdrant_url`, every embed the
  `Engram.Embedder` seam (`MockEmbedder`).

  And the migration: a point indexed before R3c is fingerprinted under the
  old inputs (the folder, the file-name title, aliases in every prefix).
  Its next edit must reuse it through the legacy candidate, or R3c itself
  would re-embed every note once.
  """
  use Engram.DataCase, async: false

  import Ecto.Query
  import Engram.IndexingTestHelpers
  import Mox

  alias Engram.Indexing
  alias Engram.Notes
  alias Engram.Notes.Chunk
  alias Engram.Notes.ChunkPoint
  alias Engram.Parsers.Markdown

  setup :set_mox_global
  setup :verify_on_exit!

  # Over 512 B: the min512 merge leaves each section its own chunk.
  @pad String.duplicate("filler words here ", 30)

  setup do
    bypass = Bypass.open()
    Engram.ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

    {:ok, recorder} = Agent.start_link(fn -> [] end)

    Bypass.stub(bypass, :any, :any, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)
      body = if body == "", do: %{}, else: Jason.decode!(body)
      Agent.update(recorder, &[%{method: conn.method, path: conn.request_path, body: body} | &1])

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true, "status": "ok"}))
    end)

    test_pid = self()

    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      send(test_pid, {:voyage, texts})
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    stub(Engram.MockEmbedder, :embed_texts, fn texts, _opts ->
      send(test_pid, {:voyage, texts})
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Test", Ecto.UUID.generate())

    %{user: user, vault: vault, recorder: recorder}
  end

  defp body(edit),
    do: "## Alpha\n\nAlpha #{@pad}\n\n## Beta\n\n#{edit} #{@pad}\n\n## Gamma\n\nGamma #{@pad}"

  defp put(ctx, path, content) do
    {:ok, note} =
      Notes.upsert_note(ctx.user, ctx.vault, %{"path" => path, "content" => content},
        actor: "api"
      )

    note
  end

  # The stored row, decrypted: what EmbedNote hands to `index_note/2`.
  defp fresh(note, ctx) do
    {:ok, note} =
      note.id
      |> Engram.Fixtures.raw_note!()
      |> Engram.Crypto.maybe_decrypt_note_fields(Repo.reload!(ctx.user, skip_tenant_check: true))

    note
  end

  defp index!(note, ctx) do
    assert {:ok, _count} = Indexing.index_note(fresh(note, ctx), ctx.vault)
  end

  defp rows(note) do
    Repo.all(from(c in Chunk, where: c.note_id == ^note.id, order_by: c.position),
      skip_tenant_check: true
    )
  end

  defp reset(ctx) do
    Agent.update(ctx.recorder, fn _ -> [] end)
    clear_vector_cache()
    flush_voyage()
  end

  defp flush_voyage do
    receive do
      {:voyage, texts} -> texts ++ flush_voyage()
    after
      0 -> []
    end
  end

  defp requests(ctx), do: ctx.recorder |> Agent.get(& &1) |> Enum.reverse()

  defp upserted(ctx) do
    for %{method: "PUT", path: p, body: b} <- requests(ctx),
        String.ends_with?(p, "/points"),
        point <- Map.get(b, "points", []),
        do: point
  end

  defp deleted(ctx) do
    for %{path: p, body: b} <- requests(ctx),
        String.ends_with?(p, "/points/delete"),
        id <- Map.get(b, "points", []),
        do: id
  end

  # The pass's fingerprint of each planned chunk (`Indexing.fingerprints/4`
  # over `fingerprint_input/1`): dense or sparse by kind, a merged group
  # under `merged/`, whose inputs are iodata.
  defp fingerprints(groups, %Engram.Accounts.User{} = user) do
    {:ok, key} =
      user |> Repo.reload!(skip_tenant_check: true) |> Engram.Crypto.dek_content_hash_key()

    fingerprints(groups, key)
  end

  defp fingerprints(groups, key) do
    Enum.map(groups, fn g ->
      kind =
        if Markdown.dense_kind?(g.kind),
          do: "dense:#{Indexing.embed_model()}/embed_text\n",
          else: "sparse\n"

      prefix = if Map.get(g, :merged, false), do: "merged/" <> kind, else: kind
      ctx = IO.iodata_to_binary(g.context_text)
      input = "#{byte_size(ctx)}:" <> ctx <> IO.iodata_to_binary(g.embed_text)
      [hmac] = Engram.Native.hmac_hex_many(key, prefix, [input])
      hmac
    end)
  end

  # The one-chunk edit: Beta's text changes, Alpha, Gamma (and any
  # frontmatter chunk) do not.
  defp assert_one_chunk_edit(ctx, note, content) do
    before = Map.new(rows(note), &{&1.position, &1.qdrant_point_id})
    reset(ctx)

    put(ctx, fresh(note, ctx).path, content)
    index!(note, ctx)

    sent = flush_voyage()
    assert length(sent) == 1, "one chunk changed, Voyage got #{length(sent)}: #{inspect(sent)}"
    assert hd(sent) =~ "Edited"

    assert length(upserted(ctx)) == 1,
           "one point to write, got #{length(upserted(ctx))}: #{inspect(requests(ctx))}"

    assert length(deleted(ctx)) == 1, "one stale point to drop: #{inspect(requests(ctx))}"

    now = Map.new(rows(note), &{&1.position, &1.qdrant_point_id})
    kept = Enum.count(now, fn {pos, id} -> before[pos] == id end)
    assert kept == map_size(now) - 1, "every unchanged chunk keeps its point"
  end

  # Prod runs INDEX_REBUILD=on, where `Rebuild.target_versions/0` is the
  # build's: any version bump here would open a new pass over every note.
  test "R3c bumps neither the chunker nor the keyword version" do
    assert {Markdown.chunker_version(), Engram.KeywordIndex.version()} == {5, 5}
  end

  describe "the next edit after a rename or a move (Engram#2523)" do
    setup ctx do
      # A note with no H1 (its file name was its title) and one with one.
      plain = put(ctx, "A/Sub/Plain Name.md", body("Beta"))
      titled = put(ctx, "A/Titled.md", "# Titled\n\n" <> body("Beta"))
      for n <- [plain, titled], do: index!(n, ctx)
      %{plain: plain, titled: titled}
    end

    test "note rename (same folder)", ctx do
      assert {:ok, _} =
               Notes.rename_note(ctx.user, ctx.vault, "A/Sub/Plain Name.md", "A/Sub/Other.md")

      assert_one_chunk_edit(ctx, ctx.plain, body("Beta Edited"))
    end

    test "note move (another folder)", ctx do
      assert {:ok, _} = Notes.rename_note(ctx.user, ctx.vault, "A/Titled.md", "B/Deep/Titled.md")
      assert_one_chunk_edit(ctx, ctx.titled, "# Titled\n\n" <> body("Beta Edited"))
    end

    test "folder rename (same parent)", ctx do
      assert {:ok, _} = Notes.rename_folder(ctx.user, ctx.vault, "A", "Z")
      assert_one_chunk_edit(ctx, ctx.plain, body("Beta Edited"))
      assert_one_chunk_edit(ctx, ctx.titled, "# Titled\n\n" <> body("Beta Edited"))
    end

    # The file name was this note's title, so a case-only rename moved every
    # chunk before R3c.
    test "case-only note rename", ctx do
      assert {:ok, _} =
               Notes.rename_note(
                 ctx.user,
                 ctx.vault,
                 "A/Sub/Plain Name.md",
                 "A/Sub/plain name.md"
               )

      assert_one_chunk_edit(ctx, ctx.plain, body("Beta Edited"))
    end

    test "folder move (into another folder)", ctx do
      assert {:ok, _} = Notes.rename_folder(ctx.user, ctx.vault, "A/Sub", "B/Sub")
      assert_one_chunk_edit(ctx, ctx.plain, body("Beta Edited"))
    end
  end

  # The cases below model an UNMOVED note 0.81.0 indexed, its rows on
  # their legacy fingerprints, then one edit. The legacy parse stands in for 0.81.0's (pinned byte for byte by
  # the frozen legacy golden set).
  defp legacy_rows!(ctx, note, groups) do
    for {g, hmac} <- Enum.zip(groups, fingerprints(groups, ctx.user)) do
      # A merged group's `member_hmacs`: its members' own legacy
      # fingerprints, leading 16 hex, as 0.81.0 wrote them.
      members =
        if Map.get(g, :merged, false),
          do: g.members |> fingerprints(ctx.user) |> Enum.map(&binary_part(&1, 0, 16))

      Repo.update_all(
        from(c in Chunk, where: c.note_id == ^note.id and c.position == ^g.position),
        [set: [context_hmac: hmac, member_hmacs: members]],
        skip_tenant_check: true
      )
    end
  end

  # `[:engram, :indexing, :chunks]` counts by outcome for one pass.
  defp capture_outcomes(fun) do
    id = "p1-#{System.unique_integer()}"
    me = self()
    handler = fn _, %{count: c}, %{outcome: o}, _ -> send(me, {:outcome, o, c}) end
    :telemetry.attach(id, [:engram, :indexing, :chunks], handler, nil)

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    Stream.repeatedly(fn ->
      receive do
        {:outcome, o, c} -> {o, c}
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
    |> Enum.reduce(%{}, fn {o, c}, acc -> Map.update(acc, o, c, &(&1 + c)) end)
  end

  # 500 sections over 512 B each: a Free note merges them (cap 128).
  defp big_sections(edit) do
    Enum.map_join(1..500, "\n\n", fn i ->
      word = if i == edit, do: "edited", else: "plain"
      "## S#{i}\n\nsection#{i} #{word} body text here. #{@pad}"
    end)
  end

  defp big_groups(content, path, opts),
    do: content |> Markdown.parse(path, opts) |> Indexing.cap_chunks(128)

  defp group_spans(groups),
    do: Enum.map(groups, &{&1.char_start, &1.char_end, Map.get(&1, :merged, false)})

  # An unmoved merged note on its legacy rows, edited at the first section
  # whose edit moves the group count as `pick` says; and, for the cost to
  # compare against, the same content and edit on a migrated note.
  defp merged_legacy_edit(ctx, pick) do
    path = "Work/Big Plan.md"
    content = big_sections(0)
    note = put(ctx, path, content)
    index!(note, ctx)
    legacy = big_groups(content, path, legacy: true)
    m = length(legacy)
    assert group_spans(legacy) == group_spans(big_groups(content, path, [])), "HARNESS"
    assert Enum.any?(legacy, &Map.get(&1, :merged, false)), "HARNESS: not merged"
    legacy_rows!(ctx, note, legacy)

    i =
      Enum.find(1..500, fn i ->
        e = big_sections(i)
        n = length(big_groups(e, path, []))

        group_spans(big_groups(e, path, legacy: true)) == group_spans(big_groups(e, path, [])) and
          case pick do
            :removed -> n < m
            :added -> n > m
            :kept -> n == m
          end
      end)

    assert i, "HARNESS: no #{pick} edit"
    edited = big_sections(i)
    n = length(big_groups(edited, path, []))

    base = put(ctx, "Work/Big Plan Base.md", content)
    index!(base, ctx)
    reset(ctx)
    put(ctx, "Work/Big Plan Base.md", edited)
    base_out = capture_outcomes(fn -> index!(base, ctx) end)
    base_sent = length(flush_voyage())

    reset(ctx)
    put(ctx, path, edited)
    out = capture_outcomes(fn -> index!(note, ctx) end)
    sent = length(flush_voyage())

    %{
      sent: sent,
      base_sent: base_sent,
      out: out,
      info:
        "edit S#{i}, #{m} -> #{n} groups; migrated: Voyage #{base_sent} " <>
          "#{inspect(base_out)}; legacy: Voyage #{sent} #{inspect(out)}"
    }
  end

  # What `legacy_twins/2` pairs on (span, then text), legacy vs R3c.
  defp twin_report(content, path) do
    old = Markdown.parse(content, path, legacy: true)
    new = Markdown.parse(content, path)

    Enum.zip_with(old, new, fn o, n ->
      %{
        span: {o.char_start, o.char_end} == {n.char_start, n.char_end},
        text: o.text == n.text,
        old_head: o.embed_text |> String.split("\n") |> hd(),
        new_head: n.embed_text |> String.split("\n") |> hd()
      }
    end)
  end

  describe "a note indexed before R3c (the legacy candidate)" do
    for {label, path, content} <- [
          {"a foldered note with an H1", "Health/Iron Panel.md", "# Iron Panel\n\n"},
          {"a note titled by its file name", "Work/Quarterly Plan.md", ""},
          {"a note with aliases", "Notes/Alias Note.md", "---\naliases: [Zed, Omega]\n---\n"}
        ] do
      test "#{label}: a one-chunk edit embeds that chunk and reuses the rest", ctx do
        path = unquote(path)
        head = unquote(content)
        note = put(ctx, path, head <> body("Beta"))
        index!(note, ctx)

        # Rewrite every row to the fingerprint the pre-R3c chunker gave it:
        # the state of every note prod indexed before this release.
        indexed = fresh(note, ctx)
        legacy = Markdown.parse(indexed.content, path, legacy: true)
        current = Markdown.parse(indexed.content, path)
        assert legacy != current, "the fixture must change under R3c"

        # The replica of the fingerprint is the pass's own: the rows match.
        assert Enum.map(rows(note), & &1.context_hmac) == fingerprints(current, ctx.user)

        for {chunk, hmac} <- Enum.zip(legacy, fingerprints(legacy, ctx.user)) do
          Repo.update_all(
            from(c in Chunk, where: c.note_id == ^note.id and c.position == ^chunk.position),
            [set: [context_hmac: hmac]],
            skip_tenant_check: true
          )
        end

        edited = head <> body("Beta Edited")
        assert_one_chunk_edit(ctx, note, edited)

        # Every row is on its R3c fingerprint from this pass on.
        new = Markdown.parse(fresh(note, ctx).content, path)
        assert Enum.map(rows(note), & &1.context_hmac) == fingerprints(new, ctx.user)
      end
    end

    # The largest notes, merged over the per-note cap (Free: 128 points):
    # their legacy twins are the legacy plan's groups, regrouped the way the
    # stored points were built, so an edit re-embeds its group, not all 128.
    test "an over-cap note: a one-chunk edit re-embeds only the changed group", ctx do
      path = "Work/Big Plan.md"

      sections = fn edit ->
        Enum.map_join(1..500, "\n\n", fn i ->
          word = if i == edit, do: "edited", else: "plain"
          "## S#{i}\n\nsection#{i} #{word} body text here. #{@pad}"
        end)
      end

      groups = &(&1 |> Markdown.parse(path, &2) |> Indexing.cap_chunks(128))
      spans = &Enum.map(&1, fn g -> {g.char_start, g.char_end, Map.get(g, :merged, false)} end)

      content = sections.(0)
      note = put(ctx, path, content)
      index!(note, ctx)
      assert length(rows(note)) <= 128

      # Simulate the pre-R3c index: the same groups, fingerprinted over the
      # legacy inputs. Valid only while both modes group alike.
      legacy = groups.(content, legacy: true)
      assert spans.(legacy) == spans.(groups.(content, []))
      assert Enum.any?(legacy, &Map.get(&1, :merged, false))

      for {group, hmac} <- Enum.zip(legacy, fingerprints(legacy, ctx.user)) do
        Repo.update_all(
          from(c in Chunk, where: c.note_id == ^note.id and c.position == ^group.position),
          [set: [context_hmac: hmac]],
          skip_tenant_check: true
        )
      end

      # An edit that keeps the grouping (one that tips `g` regroups the note
      # in either mode, a known cost).
      edited =
        Enum.find_value(240..260, fn i ->
          e = sections.(i)
          if spans.(groups.(e, [])) |> length() == length(legacy), do: e
        end)

      assert edited
      before = Map.new(rows(note), &{&1.position, &1.qdrant_point_id})
      reset(ctx)
      put(ctx, path, edited)
      index!(note, ctx)

      sent = flush_voyage()
      assert length(sent) in 1..3, "the edit's group only, Voyage got #{length(sent)}"
      kept = Enum.count(rows(note), &(before[&1.position] == &1.qdrant_point_id))
      assert kept >= map_size(before) - 3
    end

    test "an unmoved small legacy note, H1 = file name (control)", ctx do
      path = "Health/Iron Panel.md"
      note = put(ctx, path, "# Iron Panel\n\n" <> body("Beta"))
      index!(note, ctx)
      legacy_rows!(ctx, note, Markdown.parse(fresh(note, ctx).content, path, legacy: true))
      assert_one_chunk_edit(ctx, note, "# Iron Panel\n\n" <> body("Beta Edited"))
    end

    test "an unmoved legacy note whose H1 is not its file name, coalesced sections", ctx do
      path = "Projects/Meeting Notes.md"

      at = fn at, edit ->
        "# Weekly Sync\n\n" <>
          Enum.map_join(1..30, "\n\n", fn i ->
            w = if i == at, do: edit, else: "Item"
            "## Topic #{i}\n\n### Detail #{i}\n\n#{w} #{i}: a short line about this topic."
          end)
      end

      # The section to edit: the first whose edit changes one chunk only
      # (greedy coalescing can shift a member into the next chunk).
      one_chunk? = fn k ->
        a = Markdown.parse(at.(k, "Beta"), path)
        b = Markdown.parse(at.(k, "Beta Edited"), path)

        length(a) == length(b) and
          Enum.count(Enum.zip(a, b), fn {x, y} -> x.text != y.text end) == 1
      end

      k = Enum.find(1..30, one_chunk?)
      assert k, "HARNESS: no single-chunk edit"
      doc = &at.(k, &1)

      note = put(ctx, path, doc.("Beta"))
      index!(note, ctx)
      legacy = Markdown.parse(fresh(note, ctx).content, path, legacy: true)
      assert Enum.any?(legacy, &(&1.section_count > 1)), "HARNESS: no coalescing"
      # Both modes take the H1 as the title, so every chunk pairs by span
      # and text with its legacy twin.
      report = twin_report(doc.("Beta Edited"), path)

      assert Enum.all?(report, &(&1.span and &1.text and &1.old_head == &1.new_head)),
             inspect(report)

      legacy_rows!(ctx, note, legacy)
      reset(ctx)
      outcomes = capture_outcomes(fn -> assert_one_chunk_edit(ctx, note, doc.("Beta Edited")) end)
      assert outcomes.legacy == length(legacy) - 1, inspect(outcomes)
    end

    # Free: 128 points a note. An unmoved merged note on its legacy rows
    # takes a one-section edit; it must re-embed no more than the same edit
    # on a migrated note (rows on R3c fingerprints). The edit either keeps
    # the group count or moves one group boundary (the edited chunk gains or
    # loses `rem(hash, g) == 0`): both are local changes.
    for {label, pick} <- [
          {"an edit that removes a group boundary", :removed},
          {"an edit that adds a group boundary", :added},
          {"an edit that keeps the group count", :kept}
        ] do
      test "a merged legacy note, #{label}: only the edited group re-embeds", ctx do
        %{sent: sent, base_sent: base, out: out, info: info} =
          merged_legacy_edit(ctx, unquote(pick))

        assert sent <= base,
               "legacy note re-embedded #{sent} inputs, a migrated one #{base} (#{info})"

        assert Map.get(out, :legacy, 0) > 0, "no legacy reuse: #{inspect(out)}"
      end
    end

    # `resparse_note/2` on an UNEDITED merged legacy note regroups by the
    # stored row count (`merged_like/2`) and pairs the legacy twins: every
    # point must still match.
    test "a resparse of an unedited merged legacy note matches every point", ctx do
      path = "Work/Big Plan.md"
      content = big_sections(0)
      note = put(ctx, path, content)
      index!(note, ctx)
      legacy = big_groups(content, path, legacy: true)
      assert Enum.any?(legacy, &Map.get(&1, :merged, false)), "HARNESS: not merged"
      legacy_rows!(ctx, note, legacy)

      # No checksum: resparse's position-and-offsets fallback (`same_text?/3`)
      # could otherwise match every row without the legacy twins.
      ids = Enum.map(rows(note), & &1.qdrant_point_id)

      Repo.update_all(from(p in ChunkPoint, where: p.point_id in ^ids), [set: [slice_sum: nil]],
        skip_tenant_check: true
      )

      user = Repo.reload!(ctx.user, skip_tenant_check: true)
      assert {:ok, count, 0} = Indexing.resparse_note(fresh(note, ctx), user)
      assert count == length(legacy)
    end

    # Without the legacy twins a rotation would rekey only R3c fingerprints
    # and strand every row not yet moved: its next edit would re-embed.
    test "a DEK rotation rekeys a row still on its legacy fingerprint", ctx do
      path = "Health/Iron Panel.md"
      note = put(ctx, path, "# Iron Panel\n\n" <> body("Beta"))
      indexed = fresh(note, ctx)
      {old_key, new_key} = {:crypto.strong_rand_bytes(32), :crypto.strong_rand_bytes(32)}

      rekeyed = Indexing.rekey_fingerprints(indexed, old_key, new_key)
      legacy = Markdown.parse(indexed.content, path, legacy: true)

      for {old, new} <- Enum.zip(fingerprints(legacy, old_key), fingerprints(legacy, new_key)),
          do: assert(rekeyed[old] == new)
    end

    # A note already on its R3c fingerprints, every row matched, pays no
    # legacy parse: the pass's own parse is the one chunk call.
    test "a re-index of a migrated note makes exactly one chunk NIF call", ctx do
      path = "Health/Iron Panel.md"
      note = put(ctx, path, "# Iron Panel\n\n" <> body("Beta"))
      index!(note, ctx)
      put(ctx, path, "# Iron Panel\n\n" <> body("Beta Edited"))
      index!(note, ctx)

      indexed = fresh(note, ctx)
      ref = Engram.NativeScheduled.attach_nif_events()
      assert {:ok, _} = Indexing.index_note(indexed, ctx.vault)

      calls =
        Stream.repeatedly(fn ->
          receive do
            {[:engram, :nif, :call, :stop], ^ref, _, %{nif: :chunk}} -> :chunk
            {[:engram, :nif, :call, :stop], ^ref, _, _} -> :other
          after
            0 -> nil
          end
        end)
        |> Enum.take_while(& &1)
        |> Enum.count(&(&1 == :chunk))

      assert calls == 1
    end

    # Some chunks fingerprint the same in both modes (here the frontmatter
    # chunk's row is left on its R3c fingerprint). One such match must not
    # switch the candidate off for the rest of a legacy note.
    test "a chunk that matched under the new inputs does not skip the rest", ctx do
      path = "Health/Iron Panel.md"
      head = "---\ntags: [iron]\n---\n# Iron Panel\n\n"
      note = put(ctx, path, head <> body("Beta"))
      index!(note, ctx)
      legacy = Markdown.parse(fresh(note, ctx).content, path, legacy: true)
      assert List.last(legacy).kind == "frontmatter"

      for {chunk, hmac} <- Enum.zip(legacy, fingerprints(legacy, ctx.user)),
          chunk.kind != "frontmatter" do
        Repo.update_all(
          from(c in Chunk, where: c.note_id == ^note.id and c.position == ^chunk.position),
          [set: [context_hmac: hmac]],
          skip_tenant_check: true
        )
      end

      assert_one_chunk_edit(ctx, note, head <> body("Beta Edited"))
    end

    test "an unedited note re-indexes with no Voyage call and no Qdrant write", ctx do
      note = put(ctx, "Health/Iron Panel.md", "# Iron Panel\n\n" <> body("Beta"))
      index!(note, ctx)
      legacy = Markdown.parse(fresh(note, ctx).content, "Health/Iron Panel.md", legacy: true)

      for {chunk, hmac} <- Enum.zip(legacy, fingerprints(legacy, ctx.user)) do
        Repo.update_all(
          from(c in Chunk, where: c.note_id == ^note.id and c.position == ^chunk.position),
          [set: [context_hmac: hmac]],
          skip_tenant_check: true
        )
      end

      reset(ctx)
      index!(note, ctx)

      assert flush_voyage() == []
      assert upserted(ctx) == [] and deleted(ctx) == []
    end
  end
end
