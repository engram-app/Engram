# ExAws KMS traps

_Last verified: 2026-10-03_

Prod wraps every per-user DEK with AWS KMS (`KEY_PROVIDER=aws_kms`, task-role creds). Read this before touching `Engram.AwsKms.ExAws`, `KeyProvider.AwsKms`, or any `:ex_aws` config. Per-user Local→KMS migration is `Engram.Crypto.ProviderMigration` + `mix engram.migrate_provider`.

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

The S3 storage backend (AWS S3 in prod / MinIO in self-host) sets **global** `:ex_aws` creds:

```elixir
# runtime.exs, storage config, static-creds branch (MinIO / non-AWS S3)
config :ex_aws,
  access_key_id: System.fetch_env!("STORAGE_ACCESS_KEY_ID"),
  secret_access_key: System.fetch_env!("STORAGE_SECRET_ACCESS_KEY"),
  region: System.get_env("STORAGE_REGION", "auto")
```

If KMS wiring puts credentials at the same global level:

```elixir
# WRONG: overwrites the storage backend's creds
config :ex_aws,
  access_key_id: AWS_ACCESS_KEY_ID,  # Silently replaces STORAGE_ACCESS_KEY_ID
  secret_access_key: AWS_SECRET_ACCESS_KEY,
  region: AWS_REGION
```

Result: S3 attachment storage breaks at runtime. No error — just silent auth failure.

### The Fix

Always scope KMS credentials to the service-specific namespace:

```elixir
# Scoped to :ex_aws, :kms — preserves the global storage creds.
# On AWS ECS Fargate the static keys are left UNSET so ex_aws falls
# back to the task role; only region is set. Static keys are an
# opt-in (local dev / non-task-role) path:
if System.get_env("AWS_ACCESS_KEY_ID") do
  config :ex_aws, :kms,
    access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
    secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY"),
    region: System.fetch_env!("AWS_REGION")
else
  config :ex_aws, :kms, region: System.fetch_env!("AWS_REGION")
end
```

ExAws merges service-scoped config into the global namespace at request time, so both credential sets coexist. (See the `KEY_PROVIDER` block in `config/runtime.exs`.)

## Provider Tag Byte `0xAA` Rationale

Local provider uses `0x01` and `0x02` as version bytes within its own namespace. To make blobs self-identify across providers at the top level:

- AwsKms gets provider tag `0xAA` (chosen to not collide with `0x01`/`0x02`).
- `Engram.Crypto.KeyProvider.identify_from_blob/1` dispatches by leading byte:

```elixir
def identify_from_blob(<<0xAA, _rest::binary>>), do: {:ok, KeyProvider.AwsKms}
def identify_from_blob(<<0x01, 0x01, _::binary-size(60)>>), do: {:ok, KeyProvider.Local}
def identify_from_blob(<<0x02, 0x01, _::binary-size(60)>>), do: {:ok, KeyProvider.Local}
def identify_from_blob(blob) when byte_size(blob) == 60, do: {:ok, KeyProvider.Local}
def identify_from_blob(_other), do: {:error, :unrecognised_blob}
```

The read path (`Engram.Crypto`) and `ProviderMigration` both dispatch on it.

## EncryptionContext for AAD Binding

```elixir
def encryption_context(uid),
  do: %{"user_id" => to_string(uid), "purpose" => "dek_wrap"}
```

Bound on every Encrypt/Decrypt/ReEncrypt call. AWS KMS enforces it — wrong `user_id` returns `InvalidCiphertextException` (mapped to `:context_mismatch`).

IAM policy can further restrict via a `kms:EncryptionContext:purpose` StringEquals condition.

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
