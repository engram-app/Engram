# Per-request overhead of the kwsearch client (POC): Elixir round trip
# through Req's pooled Finch HTTP/1.1 connection minus the server's own
# search time (`took_us`), without filters and with a 10,240-id include list
# sent as JSON UUID strings vs base64 of the 16-byte ids. Also the encode
# cost of each body on its own.
#
#   KWSEARCH_URL=http://host:7700 KWSEARCH_SECRET_FILE=... KW_USER=... KW_VAULT=... \
#     mise exec -- mix run --no-start bench/kwsearch_overhead.exs
{:ok, _} = Application.ensure_all_started(:req)

url = System.fetch_env!("KWSEARCH_URL")
secret = "KWSEARCH_SECRET_FILE" |> System.fetch_env!() |> File.read!() |> String.trim()
Application.put_env(:engram, Engram.Kwsearch, url: url, secret: secret)
user = System.fetch_env!("KW_USER")
vault = System.fetch_env!("KW_VAULT")
reps = String.to_integer(System.get_env("KW_REPS", "12"))
n = String.to_integer(System.get_env("KW_N", "300"))

# Eval-tenant note ids (kwsearch load-eval: <<0xe7a1::64, rep::32, note::32>>),
# topped up with random ids to the 10,240 cap when the tenant has fewer notes.
real =
  for rep <- 0..(reps - 1),
      note <- 0..2218,
      do: Ecto.UUID.load!(<<0xE7A1::64, rep::32, note::32>>)

ids =
  (Enum.shuffle(real) ++ Enum.map(1..10_240, fn _ -> Ecto.UUID.generate() end))
  |> Enum.take(10_240)

# Bench queries' hashed terms (same file kwsearch bench reads).
queries =
  System.fetch_env!("KW_QUERIES")
  |> File.read!()
  |> Jason.decode!()
  |> Map.fetch!("queries")
  |> Enum.map(& &1["terms"])
  |> Enum.take(n)

pct = fn xs ->
  s = Enum.sort(xs)
  at = fn q -> Enum.at(s, min(length(s) - 1, trunc(length(s) * q))) end
  %{p50: Float.round(at.(0.5), 3), p95: Float.round(at.(0.95), 3)}
end

time_ms = fn f ->
  t = System.monotonic_time(:microsecond)
  r = f.()
  {(System.monotonic_time(:microsecond) - t) / 1000, r}
end

base = %{user: user, vaults: [vault], limit: 40}
json_body = fn terms, inc -> Jason.encode!(Map.merge(base, %{terms: terms, include: inc})) end

b64_body = fn terms, inc ->
  Jason.encode!(Map.merge(base, %{terms: terms, include_b64: Engram.Kwsearch.encode_ids(inc)}))
end

# Encode only (each body built from the same 10,240 string ids, 200 times).
enc = fn f ->
  for(_ <- 1..200, do: elem(time_ms.(fn -> f.(hd(queries), ids) end), 0)) |> pct.()
end

IO.puts(
  "encode 10,240 ids: json #{inspect(enc.(json_body))} ms, b64 #{inspect(enc.(b64_body))} ms; " <>
    "bytes json #{byte_size(json_body.(hd(queries), ids))}, b64 #{byte_size(b64_body.(hd(queries), ids))}, " <>
    "no filter #{byte_size(Jason.encode!(Map.put(base, :terms, hd(queries))))}"
)

post = fn body ->
  Req.post!(url <> "/search",
    body: body,
    headers: [{"authorization", "Bearer " <> secret}, {"content-type", "application/json"}],
    retry: false,
    receive_timeout: 5_000,
    connect_options: [protocols: [:http1]]
  ).body
end

run = fn label, build ->
  # Warm the pool and the index once.
  Enum.each(Enum.take(queries, 20), &post.(build.(&1)))

  {tot, over} =
    queries
    |> Enum.map(fn q ->
      {ms, r} = time_ms.(fn -> post.(build.(q)) end)
      {ms, ms - r["took_us"] / 1000}
    end)
    |> Enum.unzip()

  IO.puts(
    "#{label}: total #{inspect(pct.(tot))} ms, overhead (total - server) #{inspect(pct.(over))} ms"
  )
end

run.("no filter", fn q -> Jason.encode!(Map.put(base, :terms, q)) end)
run.("include 10,240 json", fn q -> json_body.(q, ids) end)
run.("include 10,240 b64", fn q -> b64_body.(q, ids) end)

{ms, {:ok, hits}} =
  time_ms.(fn -> Engram.Kwsearch.search(user, [vault], hd(queries), include: ids) end)

IO.puts("client module, include 10,240: #{Float.round(ms, 2)} ms, #{length(hits)} hits")
