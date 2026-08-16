defmodule Engram.Notes.Utf8BackfillTest do
  use Engram.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Engram.Crypto
  alias Engram.Notes
  alias Engram.Notes.Note
  alias Engram.Notes.Utf8Backfill
  alias Engram.Repo

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Test"})
    %{user: user, vault: vault}
  end

  # Persist a row whose content decrypts to invalid UTF-8 — a legacy row written
  # before the #727/#740 write-time scrub. We write a clean note, then overwrite
  # its content ciphertext in place with bytes that are invalid UTF-8 at rest.
  defp corrupt_note!(user, vault, path) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{
        "path" => path,
        "content" => "# Title\n\nclean placeholder",
        "mtime" => 1.0
      })

    bad = "# Title\n\nlead" <> <<0xE2>> <> "byte"
    {:ok, enc} = Crypto.encrypt_note_fields(%{content: bad, title: "Title"}, user, note.id)

    {:ok, {1, _}} =
      Repo.with_tenant(user.id, fn ->
        from(n in Note, where: n.id == ^note.id)
        |> Repo.update_all(
          set: [content_ciphertext: enc.content_ciphertext, content_nonce: enc.content_nonce]
        )
      end)

    note
  end

  defp raw_content(user, note_id) do
    {:ok, note} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note_id) end)
    {:ok, decrypted} = Crypto.decrypt_note_fields_unscrubbed(note, user)
    decrypted.content
  end

  test "counts corrupt-at-rest rows without mutating them", %{user: user, vault: vault} do
    note = corrupt_note!(user, vault, "Test/Corrupt.md")

    result = Utf8Backfill.scan()

    assert result.corrupt == 1
    assert result.fixed == 0
    assert result.scanned >= 1
    # Untouched: raw decrypt is still invalid UTF-8.
    refute String.valid?(raw_content(user, note.id))
  end

  test "fix: true rewrites corrupt rows so they are valid UTF-8 at rest",
       %{user: user, vault: vault} do
    note = corrupt_note!(user, vault, "Test/Corrupt.md")

    result = Utf8Backfill.scan(fix: true)

    assert result.corrupt == 1
    assert result.fixed == 1
    # The row now decrypts to valid UTF-8 even WITHOUT the read-boundary scrub.
    assert String.valid?(raw_content(user, note.id))
  end

  test "fix repairs on the :backfill boundary, never :write (won't trip the write alert)",
       %{user: user, vault: vault} do
    corrupt_note!(user, vault, "Test/Corrupt.md")

    handler = "backfill-boundary-#{inspect(make_ref())}"

    :telemetry.attach(
      handler,
      [:engram, :notes, :utf8_scrub],
      # Forward only events from this test's own process — a concurrent async
      # test scrubbing on the :write boundary would otherwise leak into the
      # `refute_received` below (#754; handlers run in the emitter's process).
      fn _e, _meas, meta, pid -> if self() == pid, do: send(pid, {:scrub, meta}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert %{fixed: 1} = Utf8Backfill.scan(fix: true)

    assert_receive {:scrub, %{boundary: :backfill}}
    # The repair must NOT look like new client corruption, or the backfill trips
    # the boundary="write" Grafana alert it is meant to drain.
    refute_received {:scrub, %{boundary: :write}}
  end

  test "fix cleans corrupt tags now that extract_tags no longer byte-slices (#741 prod scenario)",
       %{user: user, vault: vault} do
    # Content whose (now-fixed) extract_tags re-derives to clean tags; we inject
    # the legacy byte-sliced tag (`628`+0xE2) directly into the tags column to
    # mimic the 5 prod rows. Before the regex fix, re-deriving reproduced the
    # corruption and the backfill could never reach corrupt:0.
    {:ok, note} =
      Notes.upsert_note(user, vault, %{
        "path" => "Test/EnDash.md",
        "content" => "x #628" <> <<0xE2, 0x80, 0x93>> <> " y",
        "mtime" => 1.0
      })

    {:ok, dek} = Crypto.get_dek(user)

    {tags_ct, tags_nonce} =
      Crypto.Envelope.encrypt(
        :erlang.term_to_binary([<<54, 50, 56, 226>>]),
        dek,
        Crypto.aad_for_row(:notes, :tags, note.id)
      )

    {:ok, {1, _}} =
      Repo.with_tenant(user.id, fn ->
        from(n in Note, where: n.id == ^note.id)
        |> Repo.update_all(set: [tags_ciphertext: tags_ct, tags_nonce: tags_nonce])
      end)

    assert %{corrupt: 1} = Utf8Backfill.scan()
    assert %{fixed: 1} = Utf8Backfill.scan(fix: true)
    assert %{corrupt: 0} = Utf8Backfill.scan()
  end

  test "leaves valid rows untouched (no false positives)", %{user: user, vault: vault} do
    {:ok, _} =
      Notes.upsert_note(user, vault, %{
        "path" => "Test/Clean.md",
        "content" => "# Clean\n\nall good — 日本語",
        "mtime" => 1.0
      })

    result = Utf8Backfill.scan(fix: true)

    assert result.corrupt == 0
    assert result.fixed == 0
  end

  # ---------------------------------------------------------------------------
  # Log-leak tripwire for fix_note/3's error branch
  # ---------------------------------------------------------------------------
  #
  # That branch renders whatever the `with` rejected into a Logger message
  # BODY, which RedactFilter cannot scrub — it gates metadata by key and says so
  # in its own moduledoc. `format_reason/1` drops the one content-bearing shape
  # (`{:error, :version_conflict, %Note{}}`) to a bare label and inspects the
  # rest.
  #
  # The rest includes `{:error, %Ecto.Changeset{}}`, which upsert_note/4 really
  # can return. That is safe ONLY because of two things this module does not
  # own, so both are pinned here rather than trusted:
  #
  #   1. Ecto's Inspect impl prints `data` as `#Engram.Notes.Note<>` instead of
  #      expanding the struct.
  #   2. Note.changeset/2's cast list excludes the virtual :content/:title/
  #      :path, so they never reach `changes`.
  #
  # Break either and note plaintext reappears in CloudWatch, Loki and Sentry.
  # Version conflict is not reachable from the backfill (it never declares a
  # version), which is why this pins the invariants rather than driving the
  # branch end to end.
  describe "note content cannot reach the backfill's failure log" do
    test "a changeset built from note attrs carries no plaintext", %{user: user, vault: vault} do
      secret = "Dear diary, the biopsy came back positive."

      changeset =
        Note.changeset(%Note{}, %{
          "content" => secret,
          "title" => "Biopsy results",
          "path" => "Medical/biopsy.md",
          "user_id" => user.id,
          "vault_id" => vault.id
        })

      rendered = inspect(changeset)

      refute rendered =~ secret
      refute rendered =~ "Biopsy results"
      refute rendered =~ "Medical/biopsy.md"
    end

    test "the changeset cast list never takes the virtual plaintext fields",
         %{user: user, vault: vault} do
      changeset =
        Note.changeset(%Note{}, %{
          "content" => "secret body",
          "title" => "secret title",
          "path" => "secret/path.md",
          "user_id" => user.id,
          "vault_id" => vault.id
        })

      for field <- [:content, :title, :path] do
        refute Map.has_key?(changeset.changes, field),
               "#{field} is now cast into the changeset — it will render in any " <>
                 "log line that inspects an {:error, changeset} from upsert_note"
      end
    end
  end
end
