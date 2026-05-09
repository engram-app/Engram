defmodule Engram.Crypto.KeyProvider.LocalTest do
  use ExUnit.Case, async: false
  alias Engram.Crypto.KeyProvider.Local

  setup do
    key = :crypto.strong_rand_bytes(32)
    Application.put_env(:engram, :encryption_master_key, Base.encode64(key))
    on_exit(fn -> Application.delete_env(:engram, :encryption_master_key_previous) end)
    {:ok, key: key}
  end

  test "name/0" do
    assert Local.name() == :local
  end

  test "generate_dek returns 32 bytes" do
    assert byte_size(Local.generate_dek()) == 32
  end

  test "wrap/unwrap round-trips" do
    dek = Local.generate_dek()
    {:ok, wrapped} = Local.wrap_dek(dek, %{user_id: 1})
    assert {:ok, ^dek} = Local.unwrap_dek(wrapped, %{user_id: 1})
  end

  test "wrap produces distinct blobs for same DEK" do
    dek = Local.generate_dek()
    {:ok, w1} = Local.wrap_dek(dek, %{user_id: 1})
    {:ok, w2} = Local.wrap_dek(dek, %{user_id: 1})
    refute w1 == w2
  end

  test "unwrap fails on tampered blob" do
    dek = Local.generate_dek()
    {:ok, <<first, rest::binary>>} = Local.wrap_dek(dek, %{user_id: 1})
    tampered = <<Bitwise.bxor(first, 1), rest::binary>>
    assert {:error, _} = Local.unwrap_dek(tampered, %{user_id: 1})
  end

  test "unwrap falls back to previous key during rotation" do
    old_key = :crypto.strong_rand_bytes(32)
    new_key = :crypto.strong_rand_bytes(32)

    Application.put_env(:engram, :encryption_master_key, Base.encode64(old_key))
    dek = Local.generate_dek()
    {:ok, wrapped_with_old} = Local.wrap_dek(dek, %{user_id: 1})

    Application.put_env(:engram, :encryption_master_key, Base.encode64(new_key))
    Application.put_env(:engram, :encryption_master_key_previous, Base.encode64(old_key))

    assert {:ok, ^dek} = Local.unwrap_dek(wrapped_with_old, %{user_id: 1})
  end

  test "supports_async_workers? returns true" do
    assert Local.supports_async_workers?() == true
  end

  test "rotate_wrapping re-wraps with current key" do
    dek = Local.generate_dek()
    {:ok, old_wrapped} = Local.wrap_dek(dek, %{user_id: 1})
    {:ok, new_wrapped} = Local.rotate_wrapping(old_wrapped, %{user_id: 1})
    refute old_wrapped == new_wrapped
    assert {:ok, ^dek} = Local.unwrap_dek(new_wrapped, %{user_id: 1})
  end

  describe "T3.5 / M4 — _PREVIOUS fallback gating" do
    test "gated when ctx dek_version >= master_key_version (rotated user)" do
      old_key = :crypto.strong_rand_bytes(32)
      new_key = :crypto.strong_rand_bytes(32)
      Application.put_env(:engram, :encryption_master_key, Base.encode64(old_key))
      dek = Local.generate_dek()
      {:ok, wrapped_with_old} = Local.wrap_dek(dek, %{user_id: 1})

      Application.put_env(:engram, :encryption_master_key, Base.encode64(new_key))
      Application.put_env(:engram, :encryption_master_key_previous, Base.encode64(old_key))

      :telemetry.attach(
        "fallback-gated",
        [:engram, :crypto, :previous_fallback_hit],
        fn _n, _m, meta, _ -> send(self(), {:fallback, meta}) end,
        nil
      )

      try do
        # User has been rotated to dek_version 2; current master is also v2.
        # _PREVIOUS must not rescue — caller's blob is stale data.
        assert {:error, :invalid_wrapping} =
                 Local.unwrap_dek(wrapped_with_old, %{
                   user_id: 1,
                   dek_version: 2,
                   master_key_version: 2
                 })

        # T3-audit M1 — metadata key is `:status` (consistent with
        # rotate.user + aad_rebind.user), not `:outcome`.
        assert_received {:fallback, %{status: :gated_by_dek_version} = meta}
        refute Map.has_key?(meta, :outcome), "drop legacy :outcome key"
      after
        :telemetry.detach("fallback-gated")
      end
    end

    test "ungated + rescues when ctx dek_version < master_key_version (unrotated user)" do
      old_key = :crypto.strong_rand_bytes(32)
      new_key = :crypto.strong_rand_bytes(32)
      Application.put_env(:engram, :encryption_master_key, Base.encode64(old_key))
      dek = Local.generate_dek()
      {:ok, wrapped_with_old} = Local.wrap_dek(dek, %{user_id: 1})

      Application.put_env(:engram, :encryption_master_key, Base.encode64(new_key))
      Application.put_env(:engram, :encryption_master_key_previous, Base.encode64(old_key))

      :telemetry.attach(
        "fallback-rescue",
        [:engram, :crypto, :previous_fallback_hit],
        fn _n, _m, meta, _ -> send(self(), {:fallback, meta}) end,
        nil
      )

      try do
        # Unrotated user (dek_version=1) — fallback allowed, rescues.
        assert {:ok, ^dek} =
                 Local.unwrap_dek(wrapped_with_old, %{
                   user_id: 1,
                   dek_version: 1,
                   master_key_version: 2
                 })

        assert_received {:fallback, %{status: :rescued}}
      after
        :telemetry.detach("fallback-rescue")
      end
    end

    test "explicit :disable_previous_fallback in ctx overrides version logic" do
      old_key = :crypto.strong_rand_bytes(32)
      new_key = :crypto.strong_rand_bytes(32)
      Application.put_env(:engram, :encryption_master_key, Base.encode64(old_key))
      dek = Local.generate_dek()
      {:ok, wrapped_with_old} = Local.wrap_dek(dek, %{user_id: 1})

      Application.put_env(:engram, :encryption_master_key, Base.encode64(new_key))
      Application.put_env(:engram, :encryption_master_key_previous, Base.encode64(old_key))

      assert {:error, :invalid_wrapping} =
               Local.unwrap_dek(wrapped_with_old, %{
                 user_id: 1,
                 dek_version: 1,
                 master_key_version: 2,
                 disable_previous_fallback: true
               })
    end

    test "ctx without dek_version preserves legacy fallback behavior (back-compat)" do
      old_key = :crypto.strong_rand_bytes(32)
      new_key = :crypto.strong_rand_bytes(32)
      Application.put_env(:engram, :encryption_master_key, Base.encode64(old_key))
      dek = Local.generate_dek()
      {:ok, wrapped_with_old} = Local.wrap_dek(dek, %{user_id: 1})

      Application.put_env(:engram, :encryption_master_key, Base.encode64(new_key))
      Application.put_env(:engram, :encryption_master_key_previous, Base.encode64(old_key))

      # No dek_version → no gate → fallback allowed (legacy behavior).
      assert {:ok, ^dek} = Local.unwrap_dek(wrapped_with_old, %{user_id: 1})
    end
  end

  describe "T3.4 / M2 — wrap-format versioning" do
    test "new wraps carry the v2 + algorithm header bytes (`<<0x02, 0x01, ...>>`) (T3.6 H1)" do
      # T3.6 / H1 — wrap-format version 0x02 signals AAD-bound encryption.
      # AAD = "dek:v1:<user_id>" (pulled from ctx). Enables future algorithm-
      # agility without scan-and-trial-decrypt across the encrypted_dek
      # population.
      dek = Local.generate_dek()
      {:ok, wrapped} = Local.wrap_dek(dek, %{user_id: 1})

      assert <<0x02, 0x01, _nonce::binary-size(12), _ct::binary>> = wrapped
      # 1 (ver) + 1 (alg) + 12 (nonce) + 32 (DEK plaintext) + 16 (GCM tag) = 62
      assert byte_size(wrapped) == 62
    end

    test "unwrap reads v1 (no-AAD) blobs (back-compat for T3.4 rows)" do
      # T3.4 emitted v1 wraps with no AAD. T3.6 readers MUST still round-trip
      # them so master-key rotation can convert them lazily.
      dek = Local.generate_dek()
      master = Engram.Crypto.Config.local_master_key!()
      {ct, nonce} = Engram.Crypto.Envelope.encrypt(dek, master)
      v1_blob = <<0x01, 0x01, nonce::binary-size(12), ct::binary>>

      assert byte_size(v1_blob) == 62
      assert {:ok, ^dek} = Local.unwrap_dek(v1_blob, %{user_id: 1})
    end

    test "unwrap reads legacy-format blobs (back-compat for pre-T3.4 rows)" do
      # Pre-T3.4 emitted `<<nonce::12, ct::binary>>` without a header. Existing
      # rows in DB carry that shape; unwrap MUST round-trip them so the
      # migration does not require a backfill pass.
      dek = Local.generate_dek()
      master = Engram.Crypto.Config.local_master_key!()
      {ct, nonce} = Engram.Crypto.Envelope.encrypt(dek, master)
      legacy_blob = <<nonce::binary-size(12), ct::binary>>

      assert byte_size(legacy_blob) == 60
      assert {:ok, ^dek} = Local.unwrap_dek(legacy_blob, %{user_id: 1})
    end

    test "unwrap rejects unknown wrap-format version bytes" do
      # Future-proofing: a 62-byte blob whose first byte is neither v1 nor
      # v2 must fail loudly rather than fall through to a partial parse.
      bogus = <<0x99, 0x01, :crypto.strong_rand_bytes(60)::binary>>
      assert byte_size(bogus) == 62
      assert {:error, _} = Local.unwrap_dek(bogus, %{user_id: 1})
    end
  end

  describe "rotate_dek/2" do
    setup do
      ctx = %{user_id: 12345}
      {:ok, dek_old} = {:ok, :crypto.strong_rand_bytes(32)}
      {:ok, wrapped_old} = Local.wrap_dek(dek_old, ctx)
      {:ok, ctx: ctx, dek_old: dek_old, wrapped_old: wrapped_old}
    end

    test "returns new wrapped + new plaintext DEK", %{ctx: ctx, wrapped_old: wrapped_old} do
      assert {:ok, wrapped_new, dek_new} = Local.rotate_dek(wrapped_old, ctx)
      assert is_binary(wrapped_new)
      assert byte_size(dek_new) == 32
    end

    test "produces a different DEK from the input", %{ctx: ctx, wrapped_old: wrapped_old, dek_old: dek_old} do
      assert {:ok, _wrapped_new, dek_new} = Local.rotate_dek(wrapped_old, ctx)
      refute dek_new == dek_old
    end

    test "new wrapped blob unwraps to the new DEK", %{ctx: ctx, wrapped_old: wrapped_old} do
      assert {:ok, wrapped_new, dek_new} = Local.rotate_dek(wrapped_old, ctx)
      assert {:ok, ^dek_new} = Local.unwrap_dek(wrapped_new, ctx)
    end

    test "new wrapped blob is in v2 (AAD-bound) format", %{ctx: ctx, wrapped_old: wrapped_old} do
      assert {:ok, <<0x02, 0x01, _nonce::binary-size(12), _ct::binary>>, _dek_new} =
               Local.rotate_dek(wrapped_old, ctx)
    end
  end

  describe "Logger on dual-fallback failure (T3-audit M5)" do
    test "logs error when neither current nor _PREVIOUS unwraps the DEK" do
      # T3-audit M5 — a user whose DEK cannot be unwrapped by EITHER the
      # current master key OR the configured `_PREVIOUS` is in catastrophic
      # state: their data is unrecoverable. Telemetry-only signaling is
      # not enough — this should page operators. Logger.error with
      # user_id + outcome=failed makes the failure surface in any standard
      # log pipeline regardless of telemetry handler registration.
      key_a = :crypto.strong_rand_bytes(32)
      Application.put_env(:engram, :encryption_master_key, Base.encode64(key_a))
      dek = Local.generate_dek()
      {:ok, wrapped_with_a} = Local.wrap_dek(dek, %{user_id: 9999})

      # Now point env at TWO different wrong keys — neither can unwrap.
      key_b = :crypto.strong_rand_bytes(32)
      key_c = :crypto.strong_rand_bytes(32)
      Application.put_env(:engram, :encryption_master_key, Base.encode64(key_b))
      Application.put_env(:engram, :encryption_master_key_previous, Base.encode64(key_c))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :invalid_wrapping} =
                   Local.unwrap_dek(wrapped_with_a, %{user_id: 9999})
        end)

      assert log =~ "dek unwrap failed under both current and _PREVIOUS",
             "expected error log on dual-key failure, got: #{log}"

      assert log =~ "user_id=9999",
             "log must carry user_id for triage, got: #{log}"
    end
  end
end
