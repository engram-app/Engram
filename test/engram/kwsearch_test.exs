defmodule Engram.KwsearchTest do
  # POC integration test against a RUNNING kwsearch and its throwaway feed
  # Postgres (never the app's DB). Opt in:
  #   KWSEARCH=1 KWSEARCH_URL=http://host:7700 KWSEARCH_SECRET_FILE=...
  #   KWSEARCH_FEED_DB=postgres://... mise exec -- mix test test/engram/kwsearch_test.exs
  use ExUnit.Case, async: false

  @moduletag :kwsearch

  setup_all do
    url = System.fetch_env!("KWSEARCH_URL")
    secret = "KWSEARCH_SECRET_FILE" |> System.fetch_env!() |> File.read!() |> String.trim()
    Application.put_env(:engram, Engram.Kwsearch, url: url, secret: secret)

    {:ok, db} =
      "KWSEARCH_FEED_DB"
      |> System.fetch_env!()
      |> Ecto.Repo.Supervisor.parse_url()
      |> Postgrex.start_link()

    %{db: db}
  end

  # The whole path: Elixir hashes chunk text into feed terms (NIF), writes a
  # keyword_feed row, kwsearch applies it, Elixir hashes the query (same
  # key, same NIF) and finds the chunk; a note-id exclude drops it.
  test "a feed row written from Elixir is searchable through the client", %{db: db} do
    key = :crypto.strong_rand_bytes(32)
    [user, vault, note, point] = for _ <- 1..4, do: Ecto.UUID.generate()
    text = "Quarterly zymurgy notes: the fermentation schedule moved to Tuesday."
    [terms] = Engram.Native.keyword_feed_terms_nif([text], key, "en")

    Postgrex.query!(
      db,
      "INSERT INTO keyword_feed (user_id, op, vault_id, note_id, point_id, stamp, terms) VALUES ($1, 1, $2, $3, $4, 1, $5)",
      Enum.map([user, vault, note, point], &Ecto.UUID.dump!/1) ++ [terms]
    )

    {dims, _} = Engram.Native.encode_query_nif("zymurgy fermentation", key, "en")

    assert {:ok, [{^point, score}]} = poll(fn -> Engram.Kwsearch.search(user, [vault], dims) end)
    assert score > 0
    assert {:ok, []} = Engram.Kwsearch.search(user, [vault], dims, exclude: [note])
    assert {:ok, [{^point, _}]} = Engram.Kwsearch.search(user, [vault], dims, include: [note])
    # Another user's hashes of the same words find nothing (per-user term space).
    assert {:ok, []} = Engram.Kwsearch.search(Ecto.UUID.generate(), [vault], dims)

    assert {:error, :too_many_ids} =
             Engram.Kwsearch.search(user, [vault], dims, include: List.duplicate(note, 10_241))
  end

  defp poll(fun, tries \\ 50) do
    case fun.() do
      {:ok, [_ | _]} = ok -> ok
      _ when tries > 0 -> Process.sleep(200) && poll(fun, tries - 1)
      other -> other
    end
  end
end
