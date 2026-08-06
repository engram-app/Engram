defmodule Engram.Workers.BackfillNoteLinksTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query
  import Engram.Fixtures

  alias Engram.Accounts.User
  alias Engram.Attachments.Attachment
  alias Engram.Crypto
  alias Engram.Links
  alias Engram.Links.Backfill
  alias Engram.Links.NoteLink
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Workers.BackfillNoteLinks

  @zero_cursor "00000000-0000-0000-0000-000000000000"

  setup do
    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "BackfillTest"})

    %{user: user, vault: vault}
  end

  # insert_note!/insert_attachment! stamp basename_hmac like production writers
  # already do (Task 4) — legacy pre-Task-4 rows never got that stamp, so we
  # null it back out here to simulate them.
  defp null_basename_hmac!(user_id, %Note{} = note) do
    Repo.with_tenant(user_id, fn ->
      from(n in Note, where: n.id == ^note.id) |> Repo.update_all(set: [basename_hmac: nil])
    end)
  end

  defp null_basename_hmac!(user_id, %Attachment{} = att) do
    Repo.with_tenant(user_id, fn ->
      from(a in Attachment, where: a.id == ^att.id) |> Repo.update_all(set: [basename_hmac: nil])
    end)
  end

  defp reload_note(user, id) do
    {:ok, note} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, id) end)
    note
  end

  defp reload_attachment(user, id) do
    {:ok, att} = Repo.with_tenant(user.id, fn -> Repo.get!(Attachment, id) end)
    att
  end

  defp all_links(user) do
    {:ok, links} = Repo.with_tenant(user.id, fn -> Repo.all(NoteLink) end)
    links
  end

  describe "full chain (note_hmacs -> attachment_hmacs -> links)" do
    test "stamps basename_hmac and builds resolvable edges for legacy rows", %{
      user: user,
      vault: vault
    } do
      a = insert_note!(user, vault, %{path: "A.md", content: "See [[B]] and [[C]]"})
      b = insert_note!(user, vault, %{path: "B.md", content: "Back to [[A]]"})
      c = insert_note!(user, vault, %{path: "C.md", content: "no links here"})
      att = insert_attachment!(user, vault, %{path: "pics/Photo.png"})

      Enum.each([a, b, c], &null_basename_hmac!(user.id, &1))
      null_basename_hmac!(user.id, att)

      assert reload_note(user, a.id).basename_hmac == nil
      assert reload_attachment(user, att.id).basename_hmac == nil
      assert all_links(user) == []

      {:ok, _job} =
        BackfillNoteLinks.new(%{
          "user_id" => user.id,
          "vault_id" => vault.id,
          "cursor" => @zero_cursor,
          "scope" => "note_hmacs"
        })
        |> Oban.insert()

      result = Oban.drain_queue(queue: :crypto_backfill, with_recursion: true)
      assert result.failure == 0, "chain must not raise/fail: #{inspect(result)}"

      {:ok, filter_key} = Crypto.dek_filter_key(user)

      expected_a = Crypto.hmac_field(filter_key, Links.basename_key("A.md"))
      expected_att = Crypto.hmac_field(filter_key, Links.basename_key("pics/Photo.png"))

      assert reload_note(user, a.id).basename_hmac == expected_a

      assert reload_note(user, b.id).basename_hmac ==
               Crypto.hmac_field(filter_key, Links.basename_key("B.md"))

      assert reload_note(user, c.id).basename_hmac ==
               Crypto.hmac_field(filter_key, Links.basename_key("C.md"))

      assert reload_attachment(user, att.id).basename_hmac == expected_att

      links = all_links(user)
      # a -> b, a -> c, b -> a; c has none
      assert length(links) == 3

      by_source = Enum.group_by(links, & &1.source_note_id)
      a_targets = by_source[a.id] |> Enum.map(& &1.target_note_id) |> Enum.sort()
      assert a_targets == Enum.sort([b.id, c.id])
      assert [%{target_note_id: a_id}] = by_source[b.id]
      assert a_id == a.id
      refute Map.has_key?(by_source, c.id)
    end

    test "re-running the whole chain is idempotent (same hmacs, same edge count)", %{
      user: user,
      vault: vault
    } do
      a = insert_note!(user, vault, %{path: "X.md", content: "link to [[Y]]"})
      b = insert_note!(user, vault, %{path: "Y.md", content: "no links"})
      Enum.each([a, b], &null_basename_hmac!(user.id, &1))

      run_chain = fn ->
        {:ok, _} =
          BackfillNoteLinks.new(%{
            "user_id" => user.id,
            "vault_id" => vault.id,
            "cursor" => @zero_cursor,
            "scope" => "note_hmacs"
          })
          |> Oban.insert()

        Oban.drain_queue(queue: :crypto_backfill, with_recursion: true)
      end

      run_chain.()

      hmac_a1 = reload_note(user, a.id).basename_hmac
      hmac_b1 = reload_note(user, b.id).basename_hmac
      links1 = all_links(user)

      run_chain.()

      assert reload_note(user, a.id).basename_hmac == hmac_a1
      assert reload_note(user, b.id).basename_hmac == hmac_b1
      links2 = all_links(user)
      assert length(links2) == length(links1)
      assert Enum.map(links2, & &1.id) |> Enum.sort() != []
    end
  end

  describe "Backfill.enqueue_all/0" do
    test "enqueues the first scope for every (user, vault) pair with notes or attachments", %{
      user: user,
      vault: vault
    } do
      _note = insert_note!(user, vault, %{path: "Solo.md"})

      assert Backfill.enqueue_all() >= 1

      assert_enqueued(
        worker: BackfillNoteLinks,
        args: %{"user_id" => user.id, "vault_id" => vault.id, "scope" => "note_hmacs"}
      )
    end
  end

  describe "perform/1 — cursor resumption within a scope" do
    test "a full batch re-enqueues a successor at the last-processed cursor", %{
      user: user,
      vault: vault
    } do
      a = insert_note!(user, vault, %{path: "First.md"})
      b = insert_note!(user, vault, %{path: "Second.md"})

      Enum.each([a, b], &null_basename_hmac!(user.id, &1))

      assert {:ok, _job} =
               perform_job(BackfillNoteLinks, %{
                 "user_id" => user.id,
                 "vault_id" => vault.id,
                 "cursor" => @zero_cursor,
                 "scope" => "note_hmacs",
                 "batch_size" => 1
               })

      assert_enqueued(
        worker: BackfillNoteLinks,
        args: %{
          "user_id" => user.id,
          "vault_id" => vault.id,
          "cursor" => a.id,
          "scope" => "note_hmacs",
          "batch_size" => 1
        }
      )
    end

    # Regression for the reviewer-identified defect: with `unique:` present
    # on the worker, a same-scope self-re-enqueue mid-run collides with its
    # own still-"executing" row under a REAL Oban dispatch (unlike
    # perform_job above, which never creates a DB row for the "currently
    # running" job) and Oban's unique-insert silently returns the existing
    # job instead of inserting the successor — the loop dies after batch 1
    # and rows past @default_batch_size (or, here, batch_size) never get
    # processed. `Oban.drain_queue/1` goes through the real fetch_jobs path
    # (state -> "executing" before perform runs), so it reproduces this.
    # Proof this test catches the regression: temporarily restoring
    # `unique: [keys: [:user_id, :vault_id, :scope], states: :incomplete]`
    # on the worker makes this test fail (only 1 of 3 notes gets a hmac,
    # the second batch's self-re-enqueue is dropped) — see task-8-report.md.
    test "survives multiple same-scope batches under real Oban dispatch (no unique collision)",
         %{user: user, vault: vault} do
      notes = for i <- 1..3, do: insert_note!(user, vault, %{path: "Real#{i}.md"})
      Enum.each(notes, &null_basename_hmac!(user.id, &1))

      {:ok, _job} =
        BackfillNoteLinks.new(%{
          "user_id" => user.id,
          "vault_id" => vault.id,
          "cursor" => @zero_cursor,
          "scope" => "note_hmacs",
          "batch_size" => 1
        })
        |> Oban.insert()

      result = Oban.drain_queue(queue: :crypto_backfill, with_recursion: true)
      assert result.failure == 0, "chain must not raise/fail: #{inspect(result)}"

      Enum.each(notes, fn note ->
        refute is_nil(reload_note(user, note.id).basename_hmac),
               "note #{note.id} never got a basename_hmac — same-scope batch loop stalled"
      end)
    end
  end

  describe "T3.7 rotation gate" do
    test "snoozes for 60 seconds when user's DEK rotation is in progress", %{
      user: user,
      vault: vault
    } do
      Repo.update_all(
        from(u in User, where: u.id == ^user.id),
        [set: [dek_rotation_locked_at: DateTime.utc_now()]],
        skip_tenant_check: true
      )

      assert {:snooze, 60} =
               perform_job(BackfillNoteLinks, %{
                 "user_id" => user.id,
                 "vault_id" => vault.id,
                 "cursor" => @zero_cursor,
                 "scope" => "note_hmacs"
               })
    end

    test "discards job when user does not exist", %{vault: vault} do
      assert {:discard, :user_deleted} =
               perform_job(BackfillNoteLinks, %{
                 "user_id" => Ecto.UUID.generate(),
                 "vault_id" => vault.id,
                 "cursor" => @zero_cursor,
                 "scope" => "note_hmacs"
               })
    end

    test "discards job when vault does not exist", %{user: user} do
      assert {:discard, :vault_deleted} =
               perform_job(BackfillNoteLinks, %{
                 "user_id" => user.id,
                 "vault_id" => Ecto.UUID.generate(),
                 "cursor" => @zero_cursor,
                 "scope" => "note_hmacs"
               })
    end
  end
end
