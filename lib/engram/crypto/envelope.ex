defmodule Engram.Crypto.Envelope do
  @moduledoc """
  Stateless AES-256-GCM authenticated encryption with associated data (AAD),
  on the Rust engine (`Engram.Native.envelope_seal/4` / `envelope_open/4`,
  `native/engram_core/src/envelope.rs`).

  Ciphertext layout returned by `encrypt/3` is `ciphertext || tag` (16-byte
  tag suffix). The nonce field is returned separately; callers store it
  alongside ciphertext.

  ## Formats

    * Format 0: 12-byte nonce field, AAD as given, body = plaintext. Byte for
      byte what the OpenSSL `:crypto` envelope wrote before the engine.
      Empty plaintext is always format 0.
    * Format 1: 13-byte nonce field `<<1, nonce::12>>`, AAD = caller AAD
      `<> "|f1"`, body = `<<codec, payload>>` (codec 0 raw, 1 one zstd frame).

  `decrypt/4` opens either, telling them apart by the nonce field's length.

  ## Compression policy

  `mode_for/1` picks the mode from the AAD's `Crypto.aad_prefix/2`
  (`compression_policy/1`): note content, CRDT state, vault index state and
  update log, and revisions get `:zstd`; attachment content `:auto`
  (sample first, skip already-compressed media); everything else, including
  wrapped DEKs and anything that packs the nonce at a fixed offset, stays
  format 0. On by default (#1872 R2, `config/config.exs`). Kill switch with no
  release: set the `ENVELOPE_COMPRESSION=false` env var and restart
  (`config/runtime.exs`); NEW writes return to format 0 and rows already in
  format 1 stay readable. Also off, automatically, while any cluster node
  cannot read format 1 (`Engram.Crypto.CompressionGate`); see
  `compression_on?/0`.

  ## AAD (T3.6 / H1)

  Every ciphertext is bound to a context string via AES-GCM's AAD slot.
  Tampering with AAD on read fails the AEAD tag check, even though AAD
  itself is not encrypted. Per-row AAD makes within-user cross-row swaps
  detectable: copying `notes.content_ciphertext + content_nonce` from row
  42 into row 99 cannot decrypt under row 99's reconstructed AAD.

  AAD shape per call site:

    * Relational rows: `Crypto.aad_for_row/3`, `<table> 0 <column> 0 <16-byte uuid>`
    * Qdrant payload: `"qdrant:<collection>:<qdrant_id>:<field>"`
    * Wrapped DEK: `"dek:v1:<user_id>"`

  ## Backwards compatibility

  Pre-T3.6 ciphertext was written with empty AAD (`<<>>`). The 2/3-arity
  `encrypt/2` / `decrypt/3` clauses delegate to the AAD-aware arity with
  `<<>>` so legacy reads keep working. Per-row `dek_version` (notes /
  attachments / vaults) and the wrap-format byte (users.encrypted_dek)
  signal whether a constructed AAD or `<<>>` should be supplied — that
  decision lives at the caller, not here.
  """

  @tag_bytes 16

  @typedoc "AES-GCM Additional Authenticated Data — bound to ciphertext but not encrypted."
  @type aad :: binary()

  @doc """
  Bytes of AEAD tag suffixed to every ciphertext by `encrypt/3`.

  `octet_length(col) - tag_bytes()` is the STORED payload size of an encrypted
  column, recoverable WITHOUT a DEK. It is the plaintext size only for a
  format 0 row; a format 1 row is compressed (or carries a 1-byte format
  prefix), so it is the stored size. `Engram.Workers.CrdtBloatSweep` uses it to
  size every note in one query while touching no key material, and reports
  stored bytes. Exposed rather than hardcoded at the call site so a cipher
  change has one place to fail, not two.
  """
  # No @spec: the body returns a literal, so any integer type is a dialyzer
  # `contract_supertype` of the success typing. Same reason `Engram.Repo.maintenance/0`
  # carries none.
  def tag_bytes, do: @tag_bytes

  @doc """
  The highest envelope format this node can open. Peers call it over `:erpc`
  (`Engram.Crypto.CompressionGate`); a node without it predates format 1 and
  counts as 0. Raise it only in the release AFTER the one that can read the
  new format, never in the same one.
  """
  # No @spec: literal body, see tag_bytes/0.
  def max_read_format, do: 1

  @doc """
  The effective compression switch: the `ENVELOPE_COMPRESSION` kill switch
  AND the cluster guard (`CompressionGate.allowed?/0`, a persistent_term
  read). The write path, the `EnvelopeFormat` migration and the re-encode
  worker all read this one decision.
  """
  @spec compression_on?() :: boolean()
  def compression_on?,
    do:
      Application.get_env(:engram, :envelope_compression, false) == true and
        Engram.Crypto.CompressionGate.allowed?()

  @spec encrypt(binary(), <<_::256>>) :: {binary(), binary()}
  def encrypt(plaintext, dek), do: encrypt(plaintext, dek, <<>>)

  @spec encrypt(binary(), <<_::256>>, aad()) :: {binary(), binary()}
  def encrypt(plaintext, <<_::256>> = dek, aad)
      when is_binary(plaintext) and is_binary(aad),
      do: Engram.Native.envelope_seal(plaintext, dek, aad, mode_for(aad))

  @spec decrypt(binary(), binary(), <<_::256>>) :: {:ok, binary()} | :error
  def decrypt(ct_with_tag, nonce, dek), do: decrypt(ct_with_tag, nonce, dek, <<>>)

  @spec decrypt(binary(), binary(), <<_::256>>, aad()) :: {:ok, binary()} | :error
  def decrypt(ct_with_tag, nonce, <<_::256>> = dek, aad)
      when is_binary(ct_with_tag) and is_binary(nonce) and is_binary(aad),
      do: Engram.Native.envelope_open(ct_with_tag, nonce, dek, aad)

  def decrypt(_ct_with_tag, _nonce, <<_::256>>, _aad), do: :error

  # {table, column, mode}; prefixes come from Crypto.aad_prefix/2, the single
  # definition of the AAD shape, and are built once at compile time.
  @policy [
            {:notes, :content, :zstd},
            {:notes, :crdt_state, :zstd},
            {:vault_index_states, :state, :zstd},
            {:vault_index_update_log, :update, :zstd},
            {:note_revisions, :content, :zstd},
            {:attachments, :content, :auto}
          ]
          |> Enum.map(fn {t, c, mode} -> {Engram.Crypto.aad_prefix(t, c), mode} end)

  @doc false
  # The compression mode for a ciphertext, from its AAD's table:column. One
  # place decides, so DEK rotation and AAD rebind re-encrypt with the same
  # mode as the original write. On by default; `ENVELOPE_COMPRESSION=false`
  # or a cluster node that cannot read format 1 turns it off.
  def mode_for(aad) do
    if compression_on?(),
      do: compression_policy(aad),
      else: :none
  end

  @doc false
  def compression_policy(aad) do
    Enum.find_value(@policy, :none, fn {prefix, mode} ->
      if String.starts_with?(aad, prefix), do: mode
    end)
  end
end
