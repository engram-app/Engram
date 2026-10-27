defmodule Engram.Indexing.PayloadV6DbParityTest do
  @moduledoc """
  Parity through Postgres: the rows are written by the app's own indexing pass
  (`prepare_index` + `commit_index`) and read back as `NoteAttr` structs, so a
  column round trip (float, bytea, bigint, smallint) or a missing field would
  show. The expected side is the extracting builder, `Indexing.expected_v5_payload/2`
  (the v5 payload), moved to v6's two differences: `f` and the order of `fa`.
  """
  use Engram.DataCase, async: false

  import Ecto.Query
  import Mox

  alias Engram.Crypto
  alias Engram.Indexing
  alias Engram.Indexing.PayloadV6
  alias Engram.Notes
  alias Engram.Notes.{FlatFields, FrontmatterKeys, Note, NoteAttr}
  alias Engram.Repo
  alias Engram.Vector.FilterId

  setup :verify_on_exit!

  @body "\n# T\n\nBody text that yields at least one chunk.\n"
  @long String.duplicate("x", 300)

  @shapes %{
    "string" => "status: draft\nauthor: Ada\nmood: calm",
    "number" => "priority: 3\nrating: 4.5\nlevel: 7",
    "date" =>
      "updated: 2026-10-01T10:00:00Z\ndue: 2026-11-01\nexpires: 2026-12-01\nreleased: 2026-01-05",
    "list" => "source: [a, b, c]\nlabels: [x, y]",
    "bool" => "status: stable\npublished: true",
    "nested tags" => "tags: [a/b, a/b/c, plain]\ntype: Playbook",
    "empty frontmatter" => "",
    "unicode keys" => "stimmung: fröhlich\n日本語: 値\nmood: 😀",
    "dotted and spaced keys" => "a.b: 1\nmy key: spaced\n\"x y.z\": v",
    "numeric looking strings" => "code: \"007\"\nlevel: \"7\"\npriority: \"3\"\nstatus: 2",
    "boolean like strings" => "flag: \"yes\"\nother: \"true\"\nnull_s: \"null\"",
    "empty arrays and nulls" => "labels: []\nowner: null\nauthor:\nsource: []",
    "long values" => "note: #{@long}\nok: short\nlist: [#{@long}, fine]",
    "status casing" => "status: \" STABLE \"",
    "source scalar" => "source: https://only.one",
    "duplicate keys" => "mood: calm\nmood: tense",
    "verified block" =>
      "verified:\n  - by: carol\n    at: 2026-05-01T00:00:00Z\nreviewed: 2026-04-02",
    "mixed attr and num" => "level: 7\nlevel2: \"7\"\nratio: 0.5",
    "many list items" => "items: [#{Enum.map_join(1..70, ", ", &"i#{&1}")}]"
  }

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    Bypass.stub(bypass, :any, :any, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true, "status": "ok"}))
    end)

    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    user = insert(:user)
    vault = insert(:vault, user: user)
    {:ok, user: user, vault: vault}
  end

  defp content(fm, eol) do
    text = if fm == "", do: "---\n---\n" <> @body, else: "---\n" <> fm <> "\n---\n" <> @body
    String.replace(text, "\n", eol)
  end

  # What EmbedNote stamps when a pass finishes on the current text.
  defp index!(user, vault, path, content) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => content, "mtime" => 1.0},
        actor: "api"
      )

    user = Repo.get!(Engram.Accounts.User, user.id)
    {:ok, prepared} = Indexing.prepare_index(note, vault, user)
    {:ok, _} = Indexing.commit_index(prepared)

    {1, _} =
      Repo.update_all(
        from(n in Note, where: n.id == ^note.id),
        [set: [embed_hash: note.content_hash]],
        skip_tenant_check: true
      )

    {Repo.get!(Note, note.id, skip_tenant_check: true), user}
  end

  defp rows(note),
    do: Repo.all(from(a in NoteAttr, where: a.note_id == ^note.id), skip_tenant_check: true)

  defp assert_parity(note, user) do
    {:ok, plain} = Crypto.maybe_decrypt_note_fields(note, user)
    {:ok, want} = Indexing.expected_v5_payload(plain, user)
    {:ok, fk} = Crypto.dek_filter_key(user)

    rows = rows(note)
    me = self()

    got =
      PayloadV6.from_rows_or_extract(note, rows, fk, fn ->
        send(me, :extracted)
        flat_for(plain, user)
      end)

    # Rows are used whenever the pass wrote any; a note with none (no
    # frontmatter, no tags or type) takes the extracting path.
    if rows == [], do: assert_received(:extracted), else: refute_received(:extracted)
    want = want |> Map.delete("f") |> sort_fa()

    assert Map.delete(got, "f") == want
    if note.folder_ref_id, do: assert(got["f"] == FilterId.uuid(note.folder_ref_id))
    unless note.folder_ref_id, do: refute(Map.has_key?(got, "f"))
  end

  defp flat_for(plain, user) do
    {:ok, dek} = Crypto.get_dek(user)
    flat = FlatFields.extract(plain.content, Crypto.dek_filter_key_from_bytes(dek))
    {ids, _} = FrontmatterKeys.resolve(user.id, dek, flat.names)
    FlatFields.put_key_ids(flat, ids)
  end

  defp sort_fa(%{"fa" => fa} = p), do: %{p | "fa" => Enum.sort(fa)}
  defp sort_fa(p), do: p

  for {name, fm} <- @shapes, {eol, label} <- [{"\n", "LF"}, {"\r\n", "CRLF"}] do
    test "#{name} (#{label}) in a nested folder", %{user: user, vault: vault} do
      {note, user} =
        index!(user, vault, "Deep/Er/n.md", content(unquote(fm), unquote(eol)))

      assert note.folder_ref_id
      assert_parity(note, user)
    end
  end

  # Tripwire for the R-b flip: `@version` 6 with `expected_v5_payload/2` still at
  # the sweep's seam would stamp every note "v6" holding v5 content.
  test "once the version is 6 or more the sweep's builder emits the folder row id", ctx do
    {note, user} = index!(ctx.user, ctx.vault, "Deep/n.md", content("author: Ada", "\n"))
    {:ok, plain} = Crypto.maybe_decrypt_note_fields(note, user)
    {:ok, payload} = Indexing.expected_v5_payload(plain, user)

    if PayloadV6.version() >= 6,
      do: assert(payload["f"] == FilterId.uuid(note.folder_ref_id)),
      else: assert(payload["f"] == FilterId.from_hmac(note.folder_hmac))
  end

  test "a root note has no f, rows and extraction agree", %{user: user, vault: vault} do
    {note, user} = index!(user, vault, "Root.md", content("author: Ada\ntags: [t]", "\n"))
    refute note.folder_ref_id
    assert_parity(note, user)
  end

  test "rows older than the note's text are not used", %{user: user, vault: vault} do
    {note, user} = index!(user, vault, "A/n.md", content("author: Ada", "\n"))
    {:ok, fk} = Crypto.dek_filter_key(user)

    # Edited, not yet re-indexed: the note row moves, the rows stay.
    {:ok, edited} =
      Notes.upsert_note(
        user,
        vault,
        %{"path" => "A/n.md", "content" => content("author: Bo", "\n"), "mtime" => 2.0},
        actor: "api"
      )

    edited = Repo.get!(Note, edited.id, skip_tenant_check: true)
    refute PayloadV6.fresh?(edited)
    {:ok, plain} = Crypto.maybe_decrypt_note_fields(edited, user)
    flat = flat_for(plain, user)

    got = PayloadV6.from_rows_or_extract(edited, rows(note), fk, fn -> flat end)
    assert got == PayloadV6.build(edited, flat)
    refute got == PayloadV6.build_from_rows(edited, rows(note), fk)
    assert note.id == edited.id
  end
end
