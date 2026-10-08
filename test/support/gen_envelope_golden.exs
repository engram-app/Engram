# One-off generator for test/support/fixtures/envelope_golden.json.
# Encrypts with the :crypto-backed Engram.Crypto.Envelope. Regenerate ONLY
# under a deliberate format/version bump; the fixture is the guard that every
# ciphertext already in the database still opens after an engine swap.
#
#   MIX_ENV=test mise exec -- mix run --no-start test/support/gen_envelope_golden.exs \
#     > test/support/fixtures/envelope_golden.json
alias Engram.Crypto
alias Engram.Crypto.Envelope

uuid = fn -> Ecto.UUID.generate() end

aads = [
  "",
  Crypto.aad_for_row(:notes, :content, uuid.()),
  Crypto.aad_for_row(:notes, :crdt_state, uuid.()),
  Crypto.aad_for_row(:vault_index_states, :state, uuid.()),
  Crypto.aad_for_row(:vault_index_update_log, :update, uuid.()),
  Crypto.aad_for_row(:attachments, :content, uuid.()),
  Crypto.aad_for_row(:attachments, :path, uuid.()),
  Crypto.aad_for_row(:note_revisions, :content, uuid.()),
  Crypto.aad_for_qdrant("engram_notes", uuid.(), :text),
  Crypto.aad_for_wrapped_dek(uuid.())
]

md = File.read!("docs/context/async-indexing-pipeline.md")

repeat = fn n ->
  md |> List.duplicate(div(n, byte_size(md)) + 1) |> IO.iodata_to_binary() |> binary_part(0, n)
end

plaintexts = [
  "",
  "x",
  repeat.(100),
  repeat.(20_000),
  :crypto.strong_rand_bytes(3_000)
]

b64 = &Base.encode64/1

cases =
  for aad <- aads, plain <- plaintexts do
    key = :crypto.strong_rand_bytes(32)
    {ct, nonce} = Envelope.encrypt(plain, key, aad)

    %{
      "key" => b64.(key),
      "aad" => b64.(aad),
      "plaintext" => b64.(plain),
      "nonce" => b64.(nonce),
      "ct" => b64.(ct)
    }
  end

IO.puts(Jason.encode!(cases, pretty: true))
