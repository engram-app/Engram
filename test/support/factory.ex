defmodule Engram.Factory do
  use ExMachina.Ecto, repo: Engram.Repo

  # Phase B.3 dropped the plaintext path/folder/tags/name columns. Every
  # row now requires _ciphertext + _nonce + _hmac. For tests that don't
  # exercise decryption, these placeholder bytes satisfy the NOT NULL
  # constraints — tests that need real round-trip crypto should override
  # by encrypting through Engram.Crypto.Envelope using a real DEK.
  defp rand_binary(n \\ 16), do: :crypto.strong_rand_bytes(n)

  def user_factory do
    %Engram.Accounts.User{
      email: sequence(:email, &"user#{&1}@test.com"),
      display_name: sequence(:display_name, &"User #{&1}"),
      external_id: nil
    }
  end

  def note_factory do
    user = build(:user)

    # Phase B.4: title/content/path/folder/tags are virtual on the schema —
    # only ciphertext + HMAC + nonce columns are persisted. The bytes below
    # are random placeholders satisfying NOT NULL; tests that need real
    # decryptable content should use Engram.Fixtures.insert_note!/3.
    %Engram.Notes.Note{
      version: 1,
      content_hash: :crypto.hash(:sha256, "# Test note content") |> Base.encode16(case: :lower),
      embed_hash: nil,
      user: user,
      vault: build(:vault, user: user),
      content_ciphertext: rand_binary(),
      content_nonce: rand_binary(12),
      title_ciphertext: rand_binary(),
      title_nonce: rand_binary(12),
      tags_ciphertext: rand_binary(),
      tags_nonce: rand_binary(12),
      path_ciphertext: rand_binary(),
      path_nonce: rand_binary(12),
      path_hmac: rand_binary(32),
      folder_ciphertext: rand_binary(),
      folder_nonce: rand_binary(12),
      folder_hmac: rand_binary(32),
      tags_hmac: []
    }
  end

  def attachment_factory do
    user = build(:user)

    %Engram.Attachments.Attachment{
      content: <<0, 1, 2, 3>>,
      content_hash: :crypto.hash(:sha256, <<0, 1, 2, 3>>) |> Base.encode16(case: :lower),
      mime_type: "image/png",
      size_bytes: 4,
      content_nonce: rand_binary(12),
      user: user,
      vault: build(:vault, user: user),
      path_ciphertext: rand_binary(),
      path_nonce: rand_binary(12),
      path_hmac: rand_binary(32)
    }
  end

  def api_key_factory do
    %Engram.Accounts.ApiKey{
      key_hash:
        :crypto.hash(:sha256, "engram_" <> sequence(:key, &"key#{&1}"))
        |> Base.encode16(case: :lower),
      name: sequence(:key_name, &"Key #{&1}"),
      user: build(:user)
    }
  end

  def vault_factory do
    %Engram.Vaults.Vault{
      user: build(:user),
      slug: sequence(:vault_slug, &"vault-#{&1}"),
      is_default: false,
      name_ciphertext: rand_binary(),
      name_nonce: rand_binary(12),
      name_hmac: rand_binary(32)
    }
  end

  def plan_factory do
    %Engram.Billing.Plan{
      name: sequence(:plan_name, &"plan_#{&1}"),
      limits: %{
        "max_vaults" => 1,
        "cross_vault_search" => false,
        "vault_scoped_keys" => false
      }
    }
  end

  def user_override_factory do
    %Engram.Billing.UserOverride{
      user: build(:user),
      overrides: %{},
      reason: "test override"
    }
  end

  def subscription_factory do
    %Engram.Billing.Subscription{
      stripe_customer_id: sequence(:stripe_customer_id, &"cus_test#{&1}"),
      stripe_subscription_id: sequence(:stripe_sub_id, &"sub_test#{&1}"),
      tier: "starter",
      status: "active",
      current_period_end: DateTime.add(DateTime.utc_now(), 30, :day),
      user: build(:user)
    }
  end

  def device_authorization_factory do
    %Engram.Auth.DeviceAuthorization{
      device_code:
        sequence(:device_code, &"dc_#{&1}_#{Base.encode16(:crypto.strong_rand_bytes(8))}"),
      user_code:
        sequence(:user_code, fn _n ->
          code = String.upcase(Base.encode32(:crypto.strong_rand_bytes(4), padding: false))
          String.slice(code, 0, 4) <> "-" <> String.slice(code, 4, 4)
        end),
      client_id: sequence(:client_id, &"client_#{&1}"),
      status: "pending",
      expires_at: DateTime.add(DateTime.utc_now(), 300, :second) |> DateTime.truncate(:second)
    }
  end

  def device_refresh_token_factory do
    %Engram.Auth.DeviceRefreshToken{
      token_hash:
        sequence(:token_hash, &"hash_#{&1}_#{Base.encode16(:crypto.strong_rand_bytes(16))}"),
      user: build(:user),
      vault: build(:vault),
      expires_at:
        DateTime.add(DateTime.utc_now(), 90 * 24 * 3600, :second) |> DateTime.truncate(:second),
      revoked_at: nil
    }
  end
end
