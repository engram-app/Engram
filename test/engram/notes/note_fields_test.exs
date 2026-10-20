defmodule Engram.Notes.NoteFieldsTest do
  @moduledoc """
  The v5 flat frontmatter fields land in Postgres (the source of truth) in
  the same indexing pass as the Qdrant payload, and the two agree.
  """
  use Engram.DataCase, async: false

  import Ecto.Query
  import Mox

  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Indexing
  alias Engram.Notes
  alias Engram.Notes.Note
  alias Engram.Notes.NoteAttr
  alias Engram.Repo
  alias Engram.Vector.FilterId

  setup :verify_on_exit!

  @full """
  ---
  status: draft
  author: alice
  reviewed_by: bob
  source: [https://a, https://b]
  project: apollo
  updated: 2026-04-01T10:00:00Z
  reviewed: 2026-04-02T00:00:00Z
  expires: 2026-12-01
  due: 2026-11-01
  priority: 2
  mood: calm
  rating: 4.5
  launch: 2026-10-01
  ---
  # Fields

  Body text that yields at least one chunk.
  """

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    test_pid = self()

    Bypass.stub(bypass, :any, :any, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      if conn.method == "PUT" and conn.request_path =~ ~r{/points$},
        do: send(test_pid, {:upsert, body})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true, "status": "ok"}))
    end)

    user = insert(:user)
    vault = insert(:vault, user: user)
    {:ok, user: user, vault: vault}
  end

  defp index!(user, vault, content) do
    {:ok, note} =
      Notes.upsert_note(
        user,
        vault,
        %{"path" => "F/Fields.md", "content" => content, "mtime" => 1.0},
        actor: "api"
      )

    user = Repo.get!(Engram.Accounts.User, user.id)

    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    {:ok, prepared} = Indexing.prepare_index(note, vault, user)
    {:ok, _} = Indexing.commit_index(prepared)
    {Repo.get!(Note, note.id, skip_tenant_check: true), user}
  end

  defp attrs(note_id) do
    Repo.all(from(a in NoteAttr, where: a.note_id == ^note_id), skip_tenant_check: true)
  end

  defp decrypt!(user, note, field, ct, nonce) do
    {:ok, dek} = Crypto.get_dek(user)
    {:ok, plain} = Envelope.decrypt(ct, nonce, dek, Crypto.aad_for_row(:notes, field, note.id))
    plain
  end

  test "each exact key stores its blind index and an encrypted value", %{user: user, vault: vault} do
    {note, user} = index!(user, vault, @full)
    {:ok, fk} = Crypto.dek_filter_key(user)

    assert note.status_hmac == FilterId.value_hmac(fk, "draft")
    assert note.author_hmac == FilterId.value_hmac(fk, "alice")
    assert note.rev_by_hmac == FilterId.value_hmac(fk, "bob")
    assert note.proj_hmac == FilterId.value_hmac(fk, "apollo")

    assert note.src_hmac == [
             FilterId.value_hmac(fk, "https://a"),
             FilterId.value_hmac(fk, "https://b")
           ]

    assert decrypt!(user, note, :status, note.status_ciphertext, note.status_nonce) == "draft"
    assert decrypt!(user, note, :author, note.author_ciphertext, note.author_nonce) == "alice"

    assert decrypt!(user, note, :reviewed_by, note.reviewed_by_ciphertext, note.reviewed_by_nonce) ==
             "bob"

    assert decrypt!(user, note, :project, note.project_ciphertext, note.project_nonce) == "apollo"

    assert Jason.decode!(decrypt!(user, note, :source, note.source_ciphertext, note.source_nonce)) ==
             ["https://a", "https://b"]
  end

  test "each date and number column stores the plaintext value", %{user: user, vault: vault} do
    {note, _user} = index!(user, vault, @full)
    assert note.fm_updated == DateTime.to_unix(~U[2026-04-01 10:00:00Z])
    assert note.fm_reviewed == DateTime.to_unix(~U[2026-04-02 00:00:00Z])
    assert note.fm_expires == DateTime.to_unix(~U[2026-12-01 00:00:00Z])
    assert note.fm_due == DateTime.to_unix(~U[2026-11-01 00:00:00Z])
    assert note.fm_priority == 2.0
  end

  test "the long tail lands in note_attrs", %{user: user, vault: vault} do
    {note, user} = index!(user, vault, @full)
    {:ok, fk} = Crypto.dek_filter_key(user)
    rows = attrs(note.id)

    assert Enum.all?(rows, &(&1.user_id == user.id))
    by_key = Map.new(rows, &{&1.key_hmac, &1})
    assert by_key[FilterId.key_hmac(fk, "mood")].value_hmac == FilterId.value_hmac(fk, "calm")
    assert by_key[FilterId.key_hmac(fk, "rating")].value_num == 4.5

    assert by_key[FilterId.key_hmac(fk, "launch")].value_date ==
             DateTime.to_unix(~U[2026-10-01 00:00:00Z])

    assert map_size(by_key) == 3
  end

  test "the flat key wins over its alias, as in the payload", %{user: user, vault: vault} do
    content = "---\nauthor: alice\ngenerated:\n  by: \"agent:x\"\n---\n# T\n\nBody text here.\n"
    {note, user} = index!(user, vault, content)
    {:ok, fk} = Crypto.dek_filter_key(user)
    assert note.author_hmac == FilterId.value_hmac(fk, "alice")
  end

  test "an absent key leaves the column NULL and writes no row", %{user: user, vault: vault} do
    {note, _user} = index!(user, vault, "# Plain\n\nBody text with no frontmatter.\n")

    for col <- ~w(status_hmac author_hmac rev_by_hmac proj_hmac src_hmac status_ciphertext
                  fm_updated fm_reviewed fm_expires fm_due fm_priority)a,
        do: assert(is_nil(Map.fetch!(note, col)), "#{col}")

    assert attrs(note.id) == []
  end

  test "removing a key clears its column and its rows", %{user: user, vault: vault} do
    {note, _user} = index!(user, vault, @full)
    assert note.status_hmac != nil and attrs(note.id) != []

    {note, _user} = index!(user, vault, "---\nauthor: alice\n---\n# Fields\n\nBody text again.\n")
    assert note.status_hmac == nil and note.status_ciphertext == nil
    assert note.fm_due == nil and note.src_hmac == nil
    assert note.author_hmac != nil
    assert attrs(note.id) == []
  end

  describe "Postgres and the v5 Qdrant payload agree" do
    setup do
      Application.put_env(:engram, :write_v5_layout, true)
      on_exit(fn -> Application.delete_env(:engram, :write_v5_layout) end)
    end

    test "field for field", %{user: user, vault: vault} do
      {note, _user} = index!(user, vault, @full)
      assert_received {:upsert, body}
      %{"points" => [%{"payload" => p, "id" => id} | _]} = Jason.decode!(body)

      assert p["s"] == FilterId.from_hmac(note.status_hmac)
      assert p["a"] == FilterId.from_hmac(note.author_hmac)
      assert p["r"] == FilterId.from_hmac(note.rev_by_hmac)
      assert p["j"] == FilterId.from_hmac(note.proj_hmac)
      assert p["o"] == Enum.map(note.src_hmac, &FilterId.from_hmac/1)
      assert p["p"] == FilterId.from_hmac(note.path_hmac)
      assert p["f"] == FilterId.from_hmac(note.folder_hmac)
      assert p["u"] == FilterId.uuid(note.user_id)
      assert p["up"] == note.fm_updated
      assert p["rd"] == note.fm_reviewed
      assert p["ex"] == div(note.fm_expires, 86_400)
      assert p["du"] == div(note.fm_due, 86_400)
      assert p["pr"] == note.fm_priority

      rows = attrs(note.id)

      assert Enum.sort(p["at"]) ==
               Enum.sort(
                 for r <- rows,
                     r.value_hmac,
                     do: %{
                       "k" => FilterId.from_hmac(r.key_hmac),
                       "v" => FilterId.from_hmac(r.value_hmac)
                     }
               )

      assert p["nm"] ==
               for(
                 r <- rows,
                 r.value_num,
                 do: %{"k" => FilterId.from_hmac(r.key_hmac), "n" => r.value_num}
               )

      assert p["dt"] ==
               for(
                 r <- rows,
                 r.value_date,
                 do: %{"k" => FilterId.from_hmac(r.key_hmac), "t" => r.value_date}
               )

      # Deterministic v5 id, no text in the payload.
      assert String.at(id, 14) == "5"
      refute Map.has_key?(p, "text")
    end
  end
end
