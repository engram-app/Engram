defmodule Engram.Workers.EmbedNotePointsBudgetTest do
  # async: false: the RLS control drops the connection role, and the
  # limits_enforced toggle is global app env.
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query
  import Engram.RlsCase, only: [as_prod_role: 1]
  import Mox
  import Phoenix.ChannelTest, only: [subscribe_and_join: 4, push: 3, assert_reply: 3, socket: 3]
  import Phoenix.ConnTest, only: [build_conn: 0, post: 3]

  alias Engram.Crypto
  alias Engram.Indexing
  alias Engram.Notes.Chunk
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.ServiceConfig
  alias Engram.UsageMeters
  alias Engram.Workers.EmbedNote

  @endpoint EngramWeb.Endpoint

  setup :verify_on_exit!

  # Five sections, so five chunks on a full pass.
  @content """
  # Five

  ## One

  Alpha section text.

  ## Two

  Bravo section text.

  ## Three

  Charlie section text.

  ## Four

  Delta section text.

  ## Five

  Echo section text.
  """

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

    Bypass.stub(bypass, :any, :any, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true}))
    end)

    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user, is_default: true)
    note = Engram.Fixtures.insert_note!(user, vault, %{path: "Five.md", content: @content})
    assert length(Engram.Parsers.Markdown.parse(@content, "Five.md")) == 5
    %{user: user, vault: vault, note: note}
  end

  # `count` chunk rows on filler notes, so the account already holds them.
  # One filler per 30,000 rows: `position` is a smallint, unique per note.
  # Generated in SQL: 100,000 rows through `insert_all` outlive the timeout.
  defp seed_points(user, vault, count) do
    for n <- 0..div(count - 1, 30_000) do
      size = min(30_000, count - n * 30_000)
      filler = Engram.Fixtures.insert_note!(user, vault, %{path: "Filler#{n}.md", content: "x"})

      {:ok, _} =
        Repo.with_tenant(user.id, fn ->
          Repo.query!(
            """
            INSERT INTO chunks
              (note_id, user_id, vault_id, position, char_start, char_end, qdrant_point_id, created_at)
            SELECT $1, $2, $3, g, 0, 1, gen_random_uuid(), now()
            FROM generate_series(1, $4) g
            """,
            [
              Ecto.UUID.dump!(filler.id),
              Ecto.UUID.dump!(user.id),
              Ecto.UUID.dump!(vault.id),
              size
            ]
          )
        end)
    end

    :ok
  end

  defp rows_for(note) do
    {:ok, rows} =
      Repo.with_tenant(note.user_id, fn ->
        Repo.all(from(c in Chunk, where: c.note_id == ^note.id))
      end)

    rows
  end

  defp reload(note) do
    {:ok, row} = Repo.with_tenant(note.user_id, fn -> Repo.get!(Note, note.id) end)
    row
  end

  defp stub_embedder do
    Mox.stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)
  end

  defp embed(note), do: perform_job(EmbedNote, %{"note_id" => note.id, "user_id" => note.user_id})

  defp with_limits_enforced(value) do
    prev = Application.get_env(:engram, :limits_enforced)
    Application.put_env(:engram, :limits_enforced, value)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:engram, :limits_enforced),
        else: Application.put_env(:engram, :limits_enforced, prev)
    end)
  end

  describe "full vs floor on Free (cap 10,000)" do
    test "at 9,990 a 5-chunk note gets a full index", %{user: user, vault: vault, note: note} do
      seed_points(user, vault, 9_990)
      stub_embedder()

      assert :ok = embed(note)
      assert length(rows_for(note)) == 5
      indexed = reload(note)
      assert indexed.index_tier == nil
      assert indexed.dense_indexed_hash == indexed.content_hash
    end

    # No embedder stub: any Voyage call fails the test.
    test "at 9,998 the same note is floored, unmetered", %{user: user, vault: vault, note: note} do
      seed_points(user, vault, 9_998)
      before = UsageMeters.lifetime_embed_tokens(user.id)

      assert :ok = embed(note)
      assert [%{token_count: nil}] = rows_for(note)
      assert reload(note).index_tier == "floor"
      assert UsageMeters.lifetime_embed_tokens(user.id) == before
    end

    test "the floor path never reserves or releases tokens", %{
      user: user,
      vault: vault,
      note: note
    } do
      seed_points(user, vault, 9_998)
      {:ok, note} = Crypto.maybe_decrypt_note_fields(note, user)
      parent = self()

      assert {:ok, 1, 0, false} =
               Indexing.index_note_with_usage(note, vault, user,
                 reserve_tokens: fn t -> send(parent, {:reserved, t}) && true end,
                 release_tokens: fn t -> send(parent, {:released, t}) end
               )

      refute_received {:reserved, _}
      refute_received {:released, _}
    end

    test "the note's own chunks do not count against it", %{user: user, vault: vault, note: note} do
      stub_embedder()
      assert :ok = embed(note)
      seed_points(user, vault, 9_995)

      # 10,000 rows now, five of them this note's: a re-index replaces them.
      {:ok, note} = Crypto.maybe_decrypt_note_fields(note, user)
      assert {:ok, 5, _, true} = Indexing.index_note_with_usage(note, vault, user)
      assert reload(note).index_tier == nil
    end

    test "a floor_paid note forced full over the cap stays floor_paid", %{
      user: user,
      vault: vault,
      note: note
    } do
      seed_points(user, vault, 10_000)
      {:ok, note} = Crypto.maybe_decrypt_note_fields(note, user)
      note = %{note | index_tier: "floor_paid"}

      assert {:ok, 1, 0, false} =
               Indexing.index_note_with_usage(note, vault, user, index_tier: nil)

      assert reload(note).index_tier == "floor_paid"
    end
  end

  describe "other tiers" do
    test "billing disabled at 100,000: full", %{user: user, vault: vault, note: note} do
      with_limits_enforced(false)
      seed_points(user, vault, 100_000)
      stub_embedder()

      assert :ok = embed(note)
      assert length(rows_for(note)) == 5
      assert reload(note).index_tier == nil
    end

    test "Starter at 50,000: full", %{user: user, vault: vault, note: note} do
      insert(:subscription, user: user, tier: "starter", status: "active")
      seed_points(user, vault, 50_000)
      stub_embedder()

      assert :ok = embed(note)
      assert length(rows_for(note)) == 5
      assert reload(note).index_tier == nil
    end
  end

  describe "points_budget_ok?/3" do
    test "counts under its own tenant: unscoped the rows are invisible", %{
      user: user,
      vault: vault,
      note: note
    } do
      seed_points(user, vault, 10_000)

      # Control: the app role with no tenant sees zero rows.
      assert {:returned, 0} =
               as_prod_role(fn -> Repo.aggregate(Chunk, :count, skip_tenant_check: true) end)

      # Unscoped, a count would read 0 and say yes. It sets the tenant itself.
      assert {:returned, false} =
               as_prod_role(fn -> Indexing.points_budget_ok?(user, note.id, 1) end)

      assert Indexing.points_budget_ok?(user, note.id, 0)
    end
  end

  describe "writes over the cap still succeed" do
    setup %{user: user, vault: vault} do
      seed_points(user, vault, 10_000)
      Engram.ApiEntitlementHelpers.lift_api_rps_cap!(user)
      :ok
    end

    test "REST create", %{user: user} do
      {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "budget")

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer #{api_key}")
        |> post("/api/notes", %{path: "Over.md", content: "# Over\n\nText.", mtime: 1_000.0})

      assert conn.status in [200, 201]
    end

    test "socket create", %{user: user, vault: vault} do
      sock =
        socket(EngramWeb.UserSocket, "user_#{user.id}", %{
          current_user: user,
          current_api_key: nil
        })

      {:ok, _, joined} =
        subscribe_and_join(sock, EngramWeb.CrdtChannel, "crdt:#{user.id}:#{vault.id}", %{
          "crdt_proto" => 2
        })

      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), joined.channel_pid)
      id = Ecto.UUID.generate()
      ref = push(joined, "crdt_create", %{"doc_id" => id, "path" => "Over2.md"})
      assert_reply ref, :ok, %{doc_id: ^id}
    end
  end
end
