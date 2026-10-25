defmodule Engram.Notes.NoteBodyReadTest do
  @moduledoc """
  Wave 3 migrate-data: every read of a note's body (content, CRDT state,
  manifest head) comes from `note_bodies` (`Engram.Notes.NoteBody`), with the
  `notes` columns as the per-row fallback for a note that has no body row yet.

  The proof is a split brain: the `notes` copy is overwritten at rest with a
  value the trigger does not propagate (same nonce, so `notes_sync_body`
  keeps the body row), and the read must still return the real body. Before
  the switch every one of these reads the `notes` copy and fails.

  The RLS half drops to `engram_app` (`Engram.RlsCase`): the suite connects
  as a superuser, which bypasses RLS, so only there does a body read prove
  it is tenant-scoped. `async: false` because the role change is
  connection-global.
  """
  use Engram.DataCase, async: false

  import Ecto.Query
  import Engram.RlsCase

  alias Engram.Notes
  alias Engram.Notes.NoteBody
  alias Engram.Repo

  @content "# Body\n\nthe real text\n"

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Bodies", Ecto.UUID.generate())

    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "Body.md", "content" => @content}, actor: "api")

    %{user: user, vault: vault, note: note}
  end

  defp raw!(sql, note), do: Repo.query!(sql, [Ecto.UUID.dump!(note.id)])

  defp notes_row(note) do
    %{rows: [row], columns: cols} =
      raw!("SELECT content_ciphertext, crdt_state_ciphertext FROM notes WHERE id = $1", note)

    cols |> Enum.zip(row) |> Map.new()
  end

  # Overwrites the `notes` copy only: the nonce is unchanged, so the
  # `notes_sync_body` trigger leaves the body row as it was.
  defp corrupt_notes_copy!(note, column) do
    raw!("UPDATE notes SET #{column} = '\\xdeadbeefdeadbeefdeadbeefdeadbeef' WHERE id = $1", note)
  end

  defp set_body!(note, merged) do
    Repo.query!("UPDATE note_bodies SET content_ct = $2 WHERE note_id = $1", [
      Ecto.UUID.dump!(note.id),
      merged
    ])

    read!(note.user_id, note.id, [:id, :content_ciphertext, :content_nonce])
  end

  defp read!(user_id, id, fields) do
    {:ok, row} = Repo.with_tenant(user_id, fn -> NoteBody.get(id, fields) end)
    row
  end

  describe "reads the body from note_bodies" do
    test "content: get_note decrypts the body row, not the notes copy", ctx do
      corrupt_notes_copy!(ctx.note, "content_ciphertext")

      assert {:ok, %{content: @content}} = Notes.get_note(ctx.user, ctx.vault, "Body.md")
    end

    test "CRDT state: authoritative_content rebuilds from the body row", ctx do
      # Precondition: a REST write merges into the CRDT state, so there is
      # a state to read at all.
      assert is_binary(notes_row(ctx.note)["crdt_state_ciphertext"])
      corrupt_notes_copy!(ctx.note, "crdt_state_ciphertext")

      assert {:ok, @content} = Notes.authoritative_content(ctx.user, ctx.note)
    end

    test "the catch-up page serves the body row", ctx do
      corrupt_notes_copy!(ctx.note, "content_ciphertext")

      assert {:ok, %{changes: [change]}} = Notes.list_changes_by_seq(ctx.user, ctx.vault, 0)
      assert change.content == @content
    end

    test "a note with no body row falls back to its notes columns", ctx do
      raw!("DELETE FROM note_bodies WHERE note_id = $1", ctx.note)

      assert {:ok, %{content: @content}} = Notes.get_note(ctx.user, ctx.vault, "Body.md")
      assert {:ok, @content} = Notes.authoritative_content(ctx.user, ctx.note)
    end

    test "crdt_head is the body's digest in the notes column's base64", ctx do
      digest = :crypto.strong_rand_bytes(32)

      Repo.query!("UPDATE note_bodies SET crdt_head = $2 WHERE note_id = $1", [
        Ecto.UUID.dump!(ctx.note.id),
        digest
      ])

      assert read!(ctx.user.id, ctx.note.id, [:id, :crdt_head]).crdt_head ==
               Base.url_encode64(digest, padding: false)
    end
  end

  describe "budgeted reads" do
    # The budget counts content only, and every kept note stays referenced
    # for the whole MCP call: the CRDT state (often larger) must not ride.
    test "get_notes_within never loads the CRDT state", ctx do
      assert is_binary(notes_row(ctx.note)["crdt_state_ciphertext"])

      assert [{"Body.md", fetch}] =
               Notes.get_notes_within(ctx.user, ctx.vault, ["Body.md"], 4_096)

      assert %{content: @content, crdt_state_ciphertext: nil, crdt_state_nonce: nil} = fetch.()
    end

    # The window that cuts the page runs over a NARROW pass (id, order,
    # size): the body expressions sit only in the outer select, which reads
    # the kept ids, so a row past the budget is never de-TOASTed.
    test "the catch-up page reads bodies only after the cut", ctx do
      {_, recorded} =
        Engram.QueryRecorder.record(fn ->
          {:ok, _} = Notes.list_changes_by_seq(ctx.user, ctx.vault, 0)
        end)

      [sql] = for %{sql: sql} <- recorded, sql =~ "OVER", do: sql
      [outer | inner] = String.split(sql, "OVER")

      assert outer =~ "substring("
      refute Enum.join(inner) =~ "substring(", "a body expression is inside the windowed pass"
    end
  end

  describe "the merged layout splits back to the notes pair" do
    setup ctx do
      nonce = :crypto.strong_rand_bytes(12)
      ct = :crypto.strong_rand_bytes(40)
      Map.merge(ctx, %{nonce: nonce, ct: ct})
    end

    test "format 0: a 12-byte nonce behind a 0 byte", %{note: note, nonce: nonce, ct: ct} do
      assert %{content_nonce: ^nonce, content_ciphertext: ^ct} =
               set_body!(note, <<0>> <> nonce <> ct)
    end

    test "format 1: a 13-byte nonce field led by 1", %{note: note, nonce: nonce, ct: ct} do
      field = <<1>> <> nonce
      assert %{content_nonce: ^field, content_ciphertext: ^ct} = set_body!(note, field <> ct)
    end

    test "a NULL body is a NULL pair", %{note: note} do
      assert %{content_nonce: nil, content_ciphertext: nil} = set_body!(note, nil)
    end
  end

  describe "under enforced RLS" do
    test "control: the dropped role with no tenant sees no body rows", %{note: note} do
      outcome =
        as_prod_role(fn ->
          Repo.one(
            from(b in NoteBody, where: b.note_id == ^note.id, select: count(b.note_id)),
            skip_tenant_check: true
          )
        end)

      assert outcome == {:returned, 0},
             "Harness is not engaging RLS (#{inspect(outcome)}): every assertion here is meaningless"
    end

    test "the owner reads the body row", %{user: user, note: note} do
      original = notes_row(note)["content_ciphertext"]
      corrupt_notes_copy!(note, "content_ciphertext")

      assert {:returned, {:ok, %{content_ciphertext: ^original}}} =
               as_prod_role(fn ->
                 Repo.with_tenant(user.id, fn ->
                   NoteBody.get(note.id, [:id, :content_ciphertext])
                 end)
               end)
    end

    test "another tenant reads nothing", %{note: note} do
      other = insert(:user)

      assert {:returned, {:ok, nil}} =
               as_prod_role(fn ->
                 Repo.with_tenant(other.id, fn ->
                   NoteBody.get(note.id, [:id, :content_ciphertext])
                 end)
               end)
    end
  end
end
