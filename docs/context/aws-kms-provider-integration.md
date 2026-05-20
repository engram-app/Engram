# AWS KMS Provider Integration — Phase 1 Gotchas

> Non-obvious discoveries from Phase 1 (PR #110). Prevents rediscovery in Phase 2 (BootCanary polymorphism) and Phase 3 (ProviderMigration).
>
> **Status update 2026-05-20:** Phase 2 quietly shipped — `Engram.Crypto.BootCanary.verify!/0` calls `Resolver.provider()` + `provider.boot_check/0` + `provider.unwrap_dek_no_fallback/2`. `MasterRotation` uses `Resolver.provider_for/1`. Only Phase 3 (cross-provider migration state machine) remains pending. Staging cutover docs in workspace plan `ok-i-think-we-shimmying-duckling.md`.

## Architecture — Three Layers

- **`Engram.Crypto.KeyProvider.AwsKms`** — implements the cross-provider `KeyProvider` behaviour. Wraps DEKs via KMS Encrypt/Decrypt/ReEncrypt. Blob format: `<<0xAA, 0x01, kms_ciphertext::binary>>` (provider tag 0xAA, payload version 0x01).
- **`Engram.AwsKms`** — Mox seam behaviour with four callbacks: `encrypt/2`, `decrypt/2`, `re_encrypt/3`, `describe_key/0`. Returns atom-classified errors (`:access_denied`, `:throttled`, `:context_mismatch`, `:key_not_found`, `{:aws, code, message}`).
- **`Engram.AwsKms.ExAws`** — production impl wrapping `ExAws.KMS`. Resolved via `:engram, :aws_kms_client` (Mox in tests).

## ExAws KMS Gotchas Discovered via Bypass

### Function Signature: Key-First, Not Plaintext-First

```elixir
# CORRECT: key_id, then plaintext, then opts
ExAws.KMS.encrypt(key_id, plaintext, opts)

# WRONG (easy mistake):
ExAws.KMS.encrypt(plaintext, key_id, opts)
```

The AWS KMS API docs show plaintext-first; ExAws inverts that.

### Base64 Encoding Not Automatic

ExAws.KMS does **not** base64-encode plaintext/ciphertext. The AWS KMS JSON API requires base64. The production wrapper (`Engram.AwsKms.ExAws`) **must** explicitly encode:

```elixir
def encrypt(plaintext, enc_ctx) do
  key_id = key_id!()
  
  key_id
  |> ExAws.KMS.encrypt(Base.encode64(plaintext), encryption_context: enc_ctx)
  |> ExAws.request(@ex_aws_opts)
  |> case do
    {:ok, %{"CiphertextBlob" => ct_b64}} -> {:ok, Base.decode64!(ct_b64)}
    {:error, reason} -> {:error, classify(reason)}
  end
end
```

Tests (via Bypass) assert on the base64-encoded body that hits the wire, catching this drift immediately.

### Error Shape: Tuple After Retries Exhausted

After ExAws internal retries are exhausted, 4xx errors arrive as a tuple:

```elixir
{:error, {type_string, message_string}}
```

Examples: `{:error, {"AccessDeniedException", "User: arn:aws:iam::... is not authorized"}}`.

The original plan matched on `{:http_error, status, %{"__type" => ...}}` (raw HTTP shape), which is wrong for this ExAws version. The fix catches decoded tuples:

```elixir
defp classify({type, msg}) when is_binary(type) and is_binary(msg),
  do: classify_type(type, msg)
```

### Retry Policy: Disable ExAws-Level Client Retries

By default, ExAws retries `ThrottlingException` internally (~10 times). To surface throttling immediately so Oban owns retry policy:

```elixir
@ex_aws_opts [
  retries: [
    client_error_max_attempts: 1,  # Don't retry 4xx at ExAws level
    max_attempts: 3,              # OK to retry 5xx (server errors)
    base_backoff_in_ms: 10,
    max_backoff_in_ms: 1_000
  ]
]
```

### Service Config Namespace: `:ex_aws, :kms`

KMS uses the ExAws service atom `:kms`. Per-service config goes under its own namespace:

```elixir
config :ex_aws, :kms,
  access_key_id: "...",
  secret_access_key: "...",
  region: "us-east-1"
```

**See below for why this isolation matters.**

## CRITICAL — Global `:ex_aws` Config Namespace Conflict

### The Trap

The S3 storage backend (Fly Tigris) sets **global** `:ex_aws` creds:

```elixir
# runtime.exs — storage config
config :ex_aws,
  access_key_id: System.get_env("STORAGE_ACCESS_KEY_ID"),
  secret_access_key: System.get_env("STORAGE_SECRET_ACCESS_KEY"),
  region: System.get_env("STORAGE_REGION", "auto")
```

If KMS wiring puts credentials at the same global level:

```elixir
# WRONG: overwrites Tigris creds
config :ex_aws,
  access_key_id: AWS_ACCESS_KEY_ID,  # Silently replaces STORAGE_ACCESS_KEY_ID
  secret_access_key: AWS_SECRET_ACCESS_KEY,
  region: AWS_REGION
```

Result: S3 attachment storage breaks at runtime. No error — just silent auth failure.

### The Fix

Always scope KMS credentials to the service-specific namespace:

```elixir
# Scoped to :ex_aws, :kms — preserves Tigris creds
config :ex_aws, :kms,
  access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
  secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY"),
  region: System.fetch_env!("AWS_REGION")
```

ExAws merges service-scoped config into the global namespace at request time, so both credential sets coexist.

## Provider Tag Byte `0xAA` Rationale

Local provider uses `0x01` and `0x02` as version bytes within its own namespace. To make blobs self-identify across providers at the top level:

- AwsKms gets provider tag `0xAA` (chosen to not collide with `0x01`/`0x02`).
- `Engram.Crypto.KeyProvider.identify_from_blob/1` dispatches by leading byte:

```elixir
def identify_from_blob(<<0xAA, _rest::binary>>), do: :aws_kms
def identify_from_blob(<<0x01, 0x01, _::binary-size(60)>>), do: :local  # v1 = key rotation
def identify_from_blob(<<0x02, 0x01, _::binary-size(60)>>), do: :local  # v2 = key rotation
```

**Phase 1 ships this helper but does NOT wire it into read paths.** Phase 3 (ProviderMigration) will use it to route decryption during the Local→KMS migration window.

## EncryptionContext for AAD Binding

```elixir
def encryption_context(uid),
  do: %{"user_id" => to_string(uid), "purpose" => "dek_wrap"}
```

Bound on every Encrypt/Decrypt/ReEncrypt call. AWS KMS enforces it — wrong `user_id` returns `InvalidCiphertextException` (mapped to `:context_mismatch`).

IAM policy can further restrict via `kms:EncryptionContext:purpose` StringEquals condition (example in Phase 4 cutover checklist).

## Error Class Mapping

From `KeyProvider.AwsKms.unwrap_dek/2`:

```elixir
{:error, :access_denied}         # IAM denies the decrypt call
{:error, :throttled}             # Rate-limited; Oban will retry
{:error, :invalid_wrapping}      # Context mismatch (wrong user_id)
{:error, :kms_key_not_found}     # CMK deleted or disabled (distinct signal)
{:error, {:kms_decrypt_failed, reason}}  # Catch-all for other AWS errors
```

## Testing Model

- **`Engram.AwsKms.ExAws` tested via Bypass** — exercises the actual ExAws request/response shapes, catches version drift.
- **`KeyProvider.AwsKms` tested via Mox** — stubs `Engram.AwsKms`, stays hermetic.
- **Conformance suite** (`provider_conformance_test.exs`) — parametrised loop exercises both Local and AwsKms through identical assertions. AwsKms's Mox stubs use an ETS-backed `(ciphertext → plaintext)` table so wrap→unwrap round-trips work.

## Phase 1 Scope: What Ships vs Not

### Ships
- Provider + behaviour + Mox seam + conformance suite + `Config.validate!/0` extension + `runtime.exs` opt-in arm + `identify_from_blob/1` primitive.

### Does NOT Ship (at PR #110 — see status update at top)
- ~~BootCanary polymorphism (Phase 2)~~ — shipped post PR #110; see status update.
- ProviderMigration state machine (Phase 3).
- Fly secrets / IAM policy creation (Phase 4 cutover for prod). Staging cutover lives in the workspace plan, not here.
- Changes to `Engram.Crypto.get_dek/1` read paths — still read-only from configured provider; no cross-provider blob routing.

Key impl detail: All DEK operations (get/wrap/unwrap) use the configured provider, but the migration machinery to change provider per-user doesn't exist yet — staging cutover therefore wipes the DB rather than migrating.
