defmodule Engram.Crypto.KeyProvider do
  @moduledoc """
  Behaviour for wrapping/unwrapping per-user Data Encryption Keys (DEKs).
  Implementations: Local, AwsKms (future), Passphrase (future).

  `ctx` carries per-user state. AwsKms and Local ignore it; Passphrase reads it.
  """

  @type dek :: <<_::256>>
  @type wrapped :: binary()
  @type ctx :: %{:user_id => integer(), optional(:session_token) => String.t()}

  @callback name() :: atom()
  @callback generate_dek() :: dek()
  @callback wrap_dek(dek(), ctx()) :: {:ok, wrapped()} | {:error, term()}
  @callback unwrap_dek(wrapped(), ctx()) ::
              {:ok, dek()} | {:error, :needs_unlock | term()}
  @callback supports_async_workers?() :: boolean()
  @callback rotate_wrapping(wrapped(), ctx()) :: {:ok, wrapped()} | {:error, term()}

  @doc """
  T3.7 — rotate the user's DEK to a brand-new key. Default impl: generate
  a fresh DEK + wrap it. Returns both the new wrapped blob (for storage)
  and the new plaintext DEK (so the rotation orchestrator can re-encrypt
  ciphertext rows in the same pass without an extra unwrap call).

  Distinct from `rotate_wrapping/2`, which keeps the same DEK and re-wraps
  it under a new master key. `rotate_dek/2` changes the DEK identity itself,
  invalidating every ciphertext row in the user's tenant until each is
  re-encrypted under the new DEK.
  """
  @callback rotate_dek(wrapped(), ctx()) :: {:ok, wrapped(), dek()} | {:error, term()}

  @doc """
  Provider-specific pre-flight performed once at app boot, BEFORE the
  boot canary unwrap. Implementations that need to validate connectivity
  or credentials with their key source SHOULD do it here.

  - `Local` returns `:ok` (no external state).
  - `AwsKms` issues a single `DescribeKey` call against the configured
    CMK — surfaces wrong-ARN, IAM-denied, wrong-region misconfiguration
    before the first user request hits the hot path.

  No `ctx` parameter: boot check is tenant-agnostic, running once at app startup before any user context exists.
  """
  @callback boot_check() :: :ok | {:error, term()}

  @doc """
  Unwrap `wrapped` without any provider-internal fallback. Used by the
  boot canary so that a misconfigured master key cannot be silently
  rescued by a `_PREVIOUS` rotation slot. Providers without a fallback
  concept (e.g. AwsKms) MAY delegate to `unwrap_dek/2`.
  """
  @callback unwrap_dek_no_fallback(wrapped(), ctx()) ::
              {:ok, dek()} | {:error, term()}

  @doc "Default DEK generator — providers may override."
  @spec default_generate_dek() :: dek()
  def default_generate_dek, do: :crypto.strong_rand_bytes(32)

  @doc """
  Returns the KeyProvider module responsible for unwrapping `blob`, based
  on the leading bytes. Used during cross-provider migration windows so
  reads route by blob format rather than by `users.key_provider` column.

  - `<<0xAA, _::binary>>` → `Engram.Crypto.KeyProvider.AwsKms`
  - `<<0x01, _, _::binary-size(60)>>` → `Engram.Crypto.KeyProvider.Local` (v1)
  - `<<0x02, _, _::binary-size(60)>>` → `Engram.Crypto.KeyProvider.Local` (v2)
  - 60-byte raw → `Engram.Crypto.KeyProvider.Local` (pre-T3.4 legacy)
  """
  @spec identify_from_blob(term()) ::
          {:ok, module()} | {:error, :unrecognised_blob}
  def identify_from_blob(<<0xAA, _rest::binary>>),
    do: {:ok, Engram.Crypto.KeyProvider.AwsKms}

  def identify_from_blob(<<0x01, 0x01, _::binary-size(60)>>),
    do: {:ok, Engram.Crypto.KeyProvider.Local}

  def identify_from_blob(<<0x02, 0x01, _::binary-size(60)>>),
    do: {:ok, Engram.Crypto.KeyProvider.Local}

  def identify_from_blob(blob) when is_binary(blob) and byte_size(blob) == 60,
    do: {:ok, Engram.Crypto.KeyProvider.Local}

  def identify_from_blob(_other), do: {:error, :unrecognised_blob}
end
