defmodule Engram.Workers.EmbedNoteBucketQueueTest do
  # The Free embed bucket as a queue: partial passes keep existing dense
  # vectors, parked notes wait with their need, and ReconcileEmbeddings wakes
  # them first-fit by age (the oldest gets any remainder, so it cannot starve).
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query, only: [from: 2]
  import Mox

  alias Engram.Notes
  alias Engram.Notes.{Chunk, Note}
  alias Engram.Repo
  alias Engram.UsageMeters
  alias Engram.Workers.{EmbedNote, ReconcileEmbeddings}

  setup :verify_on_exit!

  @cap 6_000_000
  @words ~w(alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike
            november oscar papa quebec romeo sierra tango uniform victor whiskey xray yankee
            zulu amber basil cedar dune ember fjord grove heron iris jade kelp lotus maple
            nectar onyx pearl quartz raven sage thistle umber violet willow yarrow zinnia)

  setup do
    prev = Application.get_env(:engram, :limits_enforced)
    Application.put_env(:engram, :limits_enforced, true)

    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      Application.delete_env(:engram, :qdrant_url)

      if is_nil(prev),
        do: Application.delete_env(:engram, :limits_enforced),
        else: Application.put_env(:engram, :limits_enforced, prev)
    end)

    Bypass.stub(bypass, :any, :any, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true}))
    end)

    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp capture_embeds do
    test_pid = self()

    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      send(test_pid, {:embedded, texts})
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)
  end

  defp embedded do
    receive do
      {:embedded, texts} -> texts ++ embedded()
    after
      0 -> []
    end
  end

  defp set_bucket(user_id, tokens) do
    _ = UsageMeters.add_embed_tokens(user_id, 1)

    Repo.update_all(from(m in UsageMeters.Meter, where: m.user_id == ^user_id),
      set: [embed_bucket_tokens: tokens * 1.0, embed_bucket_at: DateTime.utc_now()]
    )
  end

  defp section(i), do: "## Section #{i}\n\n#{String.duplicate("#{Enum.at(@words, i - 1)} ", 120)}"
  defp body(n), do: Enum.map_join(1..n, "\n\n", &section/1)

  defp point_ids(note) do
    Repo.all(from(c in Chunk, where: c.note_id == ^note.id, select: c.qdrant_point_id),
      skip_tenant_check: true
    )
  end

  defp reload(note), do: Repo.get!(Note, note.id, skip_tenant_check: true)

  defp park!(note, at, need, next \\ nil) do
    Repo.update_all(
      from(n in Note, where: n.id == ^note.id),
      [
        set: [
          embed_hash: note.content_hash,
          dense_indexed_hash: nil,
          embed_retry_after: EmbedNote.parked_until_edited(),
          embed_budget_parked: true,
          embed_budget_parked_at: at,
          embed_budget_need: need,
          embed_budget_next: next
        ]
      ],
      skip_tenant_check: true
    )
  end

  defp edit(user, vault, note, content) do
    {:ok, _} =
      Notes.upsert_note(
        user,
        vault,
        %{"path" => note.path, "content" => content, "mtime" => 2_000.0},
        actor: "api"
      )

    :ok
  end

  # A dense note of `n` sections, fully embedded.
  defp dense_note(user, vault, n) do
    note =
      Engram.Fixtures.insert_note!(user, vault, %{path: "Big.md", content: "# Big\n\n" <> body(n)})

    capture_embeds()
    assert :ok = perform_job(EmbedNote, %{note_id: note.id})
    _ = embedded()
    assert reload(note).dense_indexed_hash != nil
    note
  end

  defp edit_sections(n, edited) do
    "# Big\n\n" <>
      Enum.map_join(1..n, "\n\n", fn i ->
        if i in edited,
          do: String.replace(section(i), "## Section #{i}", "## Edited #{i}"),
          else: section(i)
      end)
  end

  describe "a pass that does not fit the bucket" do
    test "one edited chunk of 50 fits: 49 dense vectors reused, 1 embedded",
         %{user: user, vault: vault} do
      note = dense_note(user, vault, 50)
      before = MapSet.new(point_ids(note))
      total = MapSet.size(before)
      assert total >= 50

      # Less than the whole note, more than one chunk.
      set_bucket(user.id, 5_000)
      edit(user, vault, note, edit_sections(50, [7]))

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      assert length(embedded()) == 1
      kept = MapSet.intersection(before, MapSet.new(point_ids(note)))
      assert MapSet.size(kept) == total - 1
      assert reload(note).dense_indexed_hash == reload(note).content_hash
    end

    test "an empty bucket keeps every existing dense vector and parks the new chunk",
         %{user: user, vault: vault} do
      note = dense_note(user, vault, 50)
      before = MapSet.new(point_ids(note))

      set_bucket(user.id, 0)
      edit(user, vault, note, edit_sections(50, [7]))

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      assert embedded() == []
      kept = MapSet.intersection(before, MapSet.new(point_ids(note)))
      assert MapSet.size(kept) == MapSet.size(before) - 1

      parked = reload(note)
      assert is_nil(parked.dense_indexed_hash)
      assert parked.embed_budget_parked == true
      assert parked.embed_budget_need > 0
      assert parked.embed_retry_after == EmbedNote.parked_until_edited()
    end

    test "embeds the new chunks that fit and parks only the rest", %{user: user, vault: vault} do
      note = dense_note(user, vault, 10)
      one_chunk = UsageMeters.estimate_tokens(section(1))

      # Room for one edited chunk, not three.
      set_bucket(user.id, one_chunk + div(one_chunk, 2))
      edit(user, vault, note, edit_sections(10, [2, 5, 8]))

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      assert length(embedded()) == 1
      parked = reload(note)
      assert parked.embed_budget_parked == true
      assert_in_delta parked.embed_budget_need, 2 * one_chunk, one_chunk
      # The next deferred chunk's estimate, for the wake guard.
      assert_in_delta parked.embed_budget_next, one_chunk, div(one_chunk, 4)
    end

    test "a new non-prose chunk does not stop later prose from fitting",
         %{user: user, vault: vault} do
      csv = fn seed ->
        rows = Enum.map_join(0..39, "\n", &"#{&1},#{&1 * seed}.25,#{rem(&1 * 31, 97)},2026-10-01")
        "## Data\n\nid,value,count,date\n" <> rows
      end

      content = fn seed, edited ->
        "# Big\n\n" <>
          Enum.map_join([1, :data, 3, 4], "\n\n", fn
            :data ->
              csv.(seed)

            i ->
              if i in edited,
                do: String.replace(section(i), "## Section", "## Edited"),
                else: section(i)
          end)
      end

      note =
        Engram.Fixtures.insert_note!(user, vault, %{path: "Big.md", content: content.(7, [])})

      assert Enum.any?(
               Engram.Parsers.Markdown.parse(content.(7, []), "Big.md"),
               &(&1.kind == "data")
             )

      capture_embeds()
      assert :ok = perform_job(EmbedNote, %{note_id: note.id})
      _ = embedded()

      # Room for one of the two edited prose chunks; the edited data chunk
      # comes first in the note and is never embedded.
      one_chunk = UsageMeters.estimate_tokens(section(1))
      set_bucket(user.id, one_chunk + div(one_chunk, 2))
      edit(user, vault, note, content.(11, [3, 4]))

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      assert [sent] = embedded()
      assert sent =~ "Edited 3"
    end
  end

  describe "the parked queue" do
    test "new work queues behind the backlog; the wake is first-fit by age",
         %{user: user, vault: vault} do
      older =
        Engram.Fixtures.insert_note!(user, vault, %{path: "Old.md", content: "# Old\n\nold words"})

      hour_ago = DateTime.add(DateTime.utc_now(), -3600, :second)
      park!(older, hour_ago, 700_000)
      set_bucket(user.id, 600_000)

      newer =
        Engram.Fixtures.insert_note!(user, vault, %{path: "New.md", content: "# New\n\nnew words"})

      # The bucket could pay for it, but an older note is waiting: no Voyage.
      capture_embeds()
      assert :ok = perform_job(EmbedNote, %{note_id: newer.id})
      assert embedded() == []

      queued = reload(newer)
      assert queued.embed_budget_parked == true
      assert DateTime.compare(queued.embed_budget_parked_at, hour_ago) == :gt

      # 600k < the head's 700k: the head is skipped, so the small newer note
      # wakes, and the head gets what is left for a partial pass.
      assert :ok = perform_job(ReconcileEmbeddings, %{})
      assert reload(newer).embed_budget_parked == nil
      assert reload(older).embed_budget_parked == nil
      assert_enqueued(worker: EmbedNote, args: %{"note_id" => newer.id})

      [head_job] = all_enqueued(worker: EmbedNote, args: %{"note_id" => older.id})
      # The bucket refills ~0.2 tokens a second while the test runs.
      assert_in_delta head_job.args["budget_cap"], 600_000 - queued.embed_budget_need, 5
    end

    test "the oldest wakes alone only once the balance covers its next chunk",
         %{user: user, vault: vault} do
      note = Engram.Fixtures.insert_note!(user, vault, %{path: "A.md", content: "# A\n\nwords"})
      park!(note, DateTime.utc_now(), 10_000, 600)

      set_bucket(user.id, 500)
      assert :ok = perform_job(ReconcileEmbeddings, %{})
      assert reload(note).embed_budget_parked == true
      refute_enqueued(worker: EmbedNote, args: %{"note_id" => note.id})

      set_bucket(user.id, 600)
      assert :ok = perform_job(ReconcileEmbeddings, %{})
      assert reload(note).embed_budget_parked == nil
      [job] = all_enqueued(worker: EmbedNote, args: %{"note_id" => note.id})
      assert job.args["budget_cap"] in 600..601
    end

    test "the wake is a no-op on an empty bucket", %{user: user, vault: vault} do
      note = Engram.Fixtures.insert_note!(user, vault, %{path: "A.md", content: "# A\n\nwords"})
      park!(note, DateTime.utc_now(), 10)
      set_bucket(user.id, 0)

      assert :ok = perform_job(ReconcileEmbeddings, %{})
      assert reload(note).embed_budget_parked == true
      refute_enqueued(worker: EmbedNote, args: %{"note_id" => note.id})
    end

    test "a woken note spends even while an older note still waits",
         %{user: user, vault: vault} do
      older = Engram.Fixtures.insert_note!(user, vault, %{path: "O.md", content: "# O\n\nold"})
      woken = Engram.Fixtures.insert_note!(user, vault, %{path: "W.md", content: "# W\n\nnew"})
      now = DateTime.utc_now()
      park!(older, DateTime.add(now, -60, :second), 700_000)
      park!(woken, now, 10)

      Repo.update_all(
        from(n in Note, where: n.id == ^woken.id),
        [set: [embed_budget_parked: nil]],
        skip_tenant_check: true
      )

      assert EmbedNote.queue_blocked?(reload(woken)) == false
      assert EmbedNote.queue_blocked?(reload(older)) == false
    end

    test "a budget-capped head pass embeds no more than its cap", %{user: user, vault: vault} do
      note = dense_note(user, vault, 10)
      one_chunk = UsageMeters.estimate_tokens(section(1))
      set_bucket(user.id, 10 * one_chunk)
      edit(user, vault, note, edit_sections(10, [2, 5, 8]))

      capture_embeds()

      assert :ok =
               perform_job(EmbedNote, %{
                 note_id: note.id,
                 user_id: user.id,
                 budget_cap: one_chunk + div(one_chunk, 2)
               })

      assert length(embedded()) == 1
      assert reload(note).embed_budget_parked == true
    end

    test "end to end: an empty bucket parks, refill re-queues, and the pass goes dense",
         %{user: user, vault: vault} do
      note =
        Engram.Fixtures.insert_note!(user, vault, %{path: "N.md", content: "# N\n\nsome words"})

      set_bucket(user.id, 0)

      assert :ok = perform_job(EmbedNote, %{note_id: note.id})
      assert reload(note).embed_budget_parked == true

      # Still empty: the sweep wakes nothing and runs no refused pass.
      assert :ok = perform_job(ReconcileEmbeddings, %{})
      assert reload(note).embed_budget_parked == true

      # A year later the bucket is full.
      Repo.update_all(from(m in UsageMeters.Meter, where: m.user_id == ^user.id),
        set: [embed_bucket_at: DateTime.add(DateTime.utc_now(), -366, :day)]
      )

      assert :ok = perform_job(ReconcileEmbeddings, %{})
      assert reload(note).embed_budget_parked == nil
      assert_enqueued(worker: EmbedNote, args: %{"note_id" => note.id})

      capture_embeds()
      assert :ok = perform_job(EmbedNote, %{note_id: note.id})
      assert embedded() != []

      done = reload(note)
      assert done.dense_indexed_hash == done.content_hash
      assert is_nil(done.embed_budget_parked_at)
      assert is_nil(done.embed_budget_need)
    end
  end

  describe "ReconcileEmbeddings.fitting/2 (oldest first, first fit)" do
    # Candidates are `{id, need, next_chunk}`, oldest first.
    test "the oldest note that fits wakes first" do
      assert ReconcileEmbeddings.fitting([{:a, 100, nil}, {:b, 50, nil}, {:c, 50, nil}], 120) ==
               [{:a, nil}]
    end

    test "a note that does not fit is skipped; smaller ones behind it wake" do
      candidates = [{:a, 50, nil}, {:b, 900, nil}, {:c, 40, nil}, {:d, 30, nil}]
      assert ReconcileEmbeddings.fitting(candidates, 100) == [{:a, nil}, {:c, nil}]
    end

    test "the oldest, skipped, still gets what is left, so it cannot starve" do
      assert ReconcileEmbeddings.fitting([{:a, 700, 400}, {:b, 100, nil}, {:c, 600, nil}], 600) ==
               [{:a, 500}, {:b, nil}]
    end

    test "the skipped oldest wakes only once what is left covers its next chunk" do
      candidates = [{:a, 700, 300}, {:b, 100, nil}]
      assert ReconcileEmbeddings.fitting(candidates, 399) == [{:b, nil}]
      assert ReconcileEmbeddings.fitting(candidates, 400) == [{:a, 300}, {:b, nil}]
    end

    test "an unknown next chunk is taken as 512 tokens" do
      assert ReconcileEmbeddings.fitting([{:a, 2_000, nil}], 511) == []
      assert ReconcileEmbeddings.fitting([{:a, 2_000, nil}], 512) == [{:a, 512}]
    end

    test "nothing wakes on an empty bucket, and nothing partial on a spent one" do
      assert ReconcileEmbeddings.fitting([{:a, 700, nil}], 0) == []
      assert ReconcileEmbeddings.fitting([{:a, 700, nil}, {:b, 100, nil}], 100) == [{:b, nil}]
    end

    test "a legacy park with no need recorded wakes once anything is left" do
      assert ReconcileEmbeddings.fitting([{:a, nil, nil}], 1) == [{:a, nil}]
    end

    test "unmetered wakes everything" do
      assert ReconcileEmbeddings.fitting([{:a, 700, 5}, {:b, nil, nil}], :unmetered) ==
               [{:a, nil}, {:b, nil}]
    end
  end

  describe "maintenance rebuilds stay unmetered" do
    test "an OrphanSweep rebuild of a dense note spends nothing from an empty bucket",
         %{user: user, vault: vault} do
      note = dense_note(user, vault, 3)
      set_bucket(user.id, 0)
      used = UsageMeters.lifetime_embed_tokens(user.id)

      assert 1 ==
               Repo.with_tenant!(user.id, fn ->
                 Engram.Indexing.flag_notes_for_rebuild([note.id], Repo)
               end)

      capture_embeds()
      assert :ok = perform_job(EmbedNote, %{note_id: note.id})

      assert embedded() != []
      assert UsageMeters.lifetime_embed_tokens(user.id) == used
      assert UsageMeters.bucket_available(user.id, @cap) == 0
      assert reload(note).dense_indexed_hash == reload(note).content_hash
    end

    test "the rename fallback re-embed of a dense note is unmetered", %{user: user, vault: vault} do
      note = dense_note(user, vault, 3)
      set_bucket(user.id, 0)
      used = UsageMeters.lifetime_embed_tokens(user.id)

      capture_embeds()

      assert :ok =
               perform_job(EmbedNote, %{
                 note_id: note.id,
                 user_id: user.id,
                 old_path_hmac: Base.encode64("old-path")
               })

      assert UsageMeters.lifetime_embed_tokens(user.id) == used
      assert reload(note).dense_indexed_hash == reload(note).content_hash
    end
  end
end
