# CPU cost of compressing one GET /api/vault/tree response at 10k notes, per
# encoding Bandit can negotiate. Before/after evidence for the origin
# compression change (SaaS: none, Cloudflare compresses at the edge;
# self-host: deflate level 1 ahead of gzip).
#
#   mise exec -- mix run bench/vault_tree_compression.exs
#
# Mirrors Bandit.Compression: gzip is `:zlib.gzip/1` (no level knob), deflate
# is a zlib stream (window_bits 15) at the configured level.
uuid = fn -> Ecto.UUID.generate() end
ts = "2026-10-17T02:04:00.123456Z"

tree = %{
  change_seq: 123_456,
  folders:
    for(
      i <- 0..199,
      do: %{id: uuid.(), name: "Area #{rem(i, 20)}/Project #{i}", count: 50, parent_id: uuid.()}
    ),
  notes:
    for(
      n <- 0..9_999,
      do: %{
        id: uuid.(),
        path: "Area #{rem(n, 20)}/Project #{rem(n, 200)}/Meeting notes #{n}.md",
        created_at: ts,
        updated_at: ts
      }
    ),
  attachments:
    for(
      a <- 0..499,
      do: %{
        id: uuid.(),
        path: "Area #{rem(a, 20)}/assets/image-#{a}.png",
        mime_type: "image/png",
        size_bytes: 123_456,
        mtime: 1_792_200_000,
        updated_at: ts
      }
    )
}

body = IO.iodata_to_binary(Jason.encode_to_iodata!(tree))

deflate = fn level ->
  fn ->
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, level, :deflated, 15, 8, :default)
    out = :zlib.deflate(z, body, :finish)
    :zlib.deflateEnd(z)
    :zlib.close(z)
    out
  end
end

variants = [
  {"identity (SaaS after: Cloudflare compresses)", fn -> body end},
  {"gzip (before: Bandit default, both modes)", fn -> :zlib.gzip(body) end},
  {"deflate level 1 (self-host after)", deflate.(1)},
  {"deflate default level", deflate.(:default)}
]

runs = 50
IO.puts("vault tree body: #{byte_size(body)} bytes, 10,000 notes; #{runs} runs each\n")

for {name, f} <- variants do
  _ = f.()
  {us, out} = :timer.tc(fn -> for _ <- 1..runs, reduce: nil, do: (_ -> f.()) end)
  size = out |> IO.iodata_length()
  IO.puts(String.pad_trailing(name, 48) <> "#{div(us, runs)} µs/response  #{size} bytes")
end
