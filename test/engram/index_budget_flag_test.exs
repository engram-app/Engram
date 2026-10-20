defmodule Engram.IndexBudgetFlagTest do
  @moduledoc """
  Review H2: nothing in the v5 index budget may change prod before the v5
  pass. With `:index_budget_enabled` off (the default), indexing and the
  04:00 UTC sweep behave as on main: no per-note merge, no floor, no
  points budget, no recap or budget jobs.
  """
  # async: false: limits_enforced and the flag are global app env.
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query
  import Mox

  alias Engram.Crypto
  alias Engram.Indexing
  alias Engram.Notes.Chunk
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.ServiceConfig
  alias Engram.Workers.{EmbedNote, RebuildStaleNote, ReconcileEmbeddings}

  setup :verify_on_exit!

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

    Bypass.stub(bypass, :any, :any, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true}))
    end)

    Mox.stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user, is_default: true)
    refute Indexing.budget_enabled?()
    %{user: user, vault: vault}
  end

  defp sections(n),
    do: "# Big\n\n" <> Enum.map_join(1..n, "\n\n", &"## S#{&1}\n\nsection#{&1} body text.")

  defp insert_note(user, vault, content) do
    note = Engram.Fixtures.insert_note!(user, vault, %{path: "Big.md", content: content})
    {:ok, note} = Crypto.maybe_decrypt_note_fields(note, user)
    note
  end

  defp rows(note) do
    {:ok, n} =
      Repo.with_tenant(note.user_id, fn ->
        Repo.aggregate(from(c in Chunk, where: c.note_id == ^note.id), :count)
      end)

    n
  end

  defp tier(note) do
    {:ok, t} =
      Repo.with_tenant(note.user_id, fn ->
        Repo.one(from(n in Note, where: n.id == ^note.id, select: n.index_tier))
      end)

    t
  end

  test "a 500-chunk Free note indexes one point a chunk, unmerged", %{user: user, vault: vault} do
    note = insert_note(user, vault, sections(500))
    assert {:ok, 500, _, true} = Indexing.index_note_with_usage(note, vault, user)
    assert rows(note) == 500
    assert tier(note) == nil
  end

  test "an account over the points cap still gets a full index", %{user: user, vault: vault} do
    insert(:user_limit_override, user: user, key: "index_points_cap", value: %{"v" => 3})
    note = insert_note(user, vault, sections(10))
    assert {:ok, 10, _, true} = Indexing.index_note_with_usage(note, vault, user)
    assert tier(note) == nil
  end

  test "the 04:00 UTC tick enqueues no recap or budget job", %{user: user, vault: vault} do
    insert(:user_limit_override, user: user, key: "index_points_cap", value: %{"v" => 3})
    note = insert_note(user, vault, sections(500))
    # The real job, so the note is stamped indexed like any prod note.
    assert :ok = perform_job(EmbedNote, %{"note_id" => note.id, "user_id" => user.id})
    assert rows(note) == 500

    tick = DateTime.new!(Date.utc_today(), ~T[04:02:00])
    assert :ok = perform_job(ReconcileEmbeddings, %{}, scheduled_at: tick)
    refute_enqueued(worker: RebuildStaleNote)
    refute_enqueued(worker: EmbedNote, args: %{"note_id" => note.id})
    assert tier(note) == nil
  end

  # `chunks.position` is a smallint: a note of more than 32,767 chunks (a
  # 30 MB self-host note of tiny sections, CI huge-notes) crashed the row
  # insert on every attempt. Over that the chunks merge to fit, budget or
  # not. Synthetic chunks: parsing that many needs a ~17 MB note.
  test "more than 32,767 chunks merge to fit the position range" do
    [template] = Engram.Parsers.Markdown.parse("# T\n\nbody", "T.md")

    chunks =
      for i <- 0..32_999 do
        text = "section#{i} body"

        %{
          template
          | position: i,
            text: text,
            context_text: "T\n\n" <> text,
            embed_text: "T\n\n" <> text
        }
      end

    fitted = Indexing.fit_positions(chunks, false)
    assert length(fitted) <= 32_767
    assert fitted |> Enum.map(& &1.position) |> Enum.max() < 32_768
    assert Indexing.fit_positions(Enum.take(chunks, 100), false) === Enum.take(chunks, 100)
  end
end
