defmodule Engram.Crypto.BootCanaryTest do
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Engram.Crypto.{BootCanary, KeyProvider.Local}
  alias Engram.Repo

  setup do
    # Each test starts from an empty canary table.
    Repo.delete_all("system_canaries")
    :ok
  end

  describe "verify!/0" do
    test "provisions a fresh canary when table is empty + emits :provisioned telemetry" do
      :telemetry.attach(
        "boot-canary-provision",
        [:engram, :crypto, :boot_canary],
        fn _name, _meas, meta, _ -> send(self(), {:canary, meta}) end,
        nil
      )

      try do
        assert :ok = BootCanary.verify!()
        assert_received {:canary, %{status: :provisioned, provider: :local}}
        assert Repo.aggregate("system_canaries", :count) == 1
      after
        :telemetry.detach("boot-canary-provision")
      end
    end

    test "verifies successfully on second call after auto-provision" do
      assert :ok = BootCanary.verify!()

      :telemetry.attach(
        "boot-canary-ok",
        [:engram, :crypto, :boot_canary],
        fn _name, _meas, meta, _ -> send(self(), {:canary, meta}) end,
        nil
      )

      try do
        assert :ok = BootCanary.verify!()
        assert_received {:canary, %{status: :ok, provider: :local}}
      after
        :telemetry.detach("boot-canary-ok")
      end
    end

    test "raises when current master key cannot unwrap canary (key mismatch)" do
      BootCanary.provision!()

      original_master = Application.get_env(:engram, :encryption_master_key)
      foreign = Base.encode64(:binary.copy(<<0xFF>>, 32))
      Application.put_env(:engram, :encryption_master_key, foreign)

      :telemetry.attach(
        "boot-canary-fail",
        [:engram, :crypto, :boot_canary],
        fn _name, _meas, meta, _ -> send(self(), {:canary, meta}) end,
        nil
      )

      try do
        assert_raise RuntimeError, ~r/boot canary unwrap failed/, fn ->
          BootCanary.verify!()
        end

        assert_received {:canary,
                         %{status: :failed, reason_label: "invalid_wrapping", provider: :local}}
      after
        :telemetry.detach("boot-canary-fail")
        Application.put_env(:engram, :encryption_master_key, original_master)
      end
    end

    test "DOES NOT use _PREVIOUS fallback (the whole point of M3)" do
      # Set up: canary wrapped with key_A. Then point env at:
      #   ENCRYPTION_MASTER_KEY        = key_B  (wrong)
      #   ENCRYPTION_MASTER_KEY_PREVIOUS = key_A  (would rescue regular unwrap)
      # Boot canary MUST raise — its purpose is to detect the operator
      # error of running on the wrong "current" key, even when _PREVIOUS
      # would silently rescue every other unwrap path.
      key_a = Application.get_env(:engram, :encryption_master_key)
      BootCanary.provision!()

      key_b = Base.encode64(:binary.copy(<<0x77>>, 32))
      Application.put_env(:engram, :encryption_master_key, key_b)
      Application.put_env(:engram, :encryption_master_key_previous, key_a)

      try do
        # Sanity: a regular Local.unwrap_dek/2 with fallback DOES succeed.
        canary_blob = Repo.one(from c in "system_canaries", select: c.wrapped_dek)
        assert {:ok, _dek} = Local.unwrap_dek(canary_blob, %{user_id: 0})

        # But boot canary refuses fallback and raises.
        assert_raise RuntimeError, ~r/boot canary unwrap failed/, fn ->
          BootCanary.verify!()
        end
      after
        Application.put_env(:engram, :encryption_master_key, key_a)
        Application.delete_env(:engram, :encryption_master_key_previous)
      end
    end

    test "raises with sha_mismatch label when canary plaintext SHA disagrees" do
      # Insert a canary row whose recorded sha256 is wrong on purpose.
      dek = :crypto.strong_rand_bytes(32)
      {:ok, wrapped} = Local.wrap_dek(dek, %{user_id: 0})
      bad_sha = :crypto.hash(:sha256, "wrong plaintext")
      now = DateTime.utc_now()

      Repo.insert_all(
        "system_canaries",
        [%{wrapped_dek: wrapped, dek_sha256: bad_sha, inserted_at: now, updated_at: now}]
      )

      assert_raise RuntimeError, ~r/does not match the recorded\s+SHA256/s, fn ->
        BootCanary.verify!()
      end
    end
  end

  describe "provision!/0" do
    test "appends a row, leaves prior rows in place" do
      BootCanary.provision!()
      BootCanary.provision!()
      assert Repo.aggregate("system_canaries", :count) == 2
    end
  end

  describe "verify!/0 — AwsKms provider" do
    import Mox
    setup :verify_on_exit!

    setup do
      prev_provider = Application.get_env(:engram, :key_provider)
      prev_client = Application.get_env(:engram, :aws_kms_client)
      Application.put_env(:engram, :key_provider, Engram.Crypto.KeyProvider.AwsKms)
      Application.put_env(:engram, :aws_kms_client, Engram.AwsKmsMock)

      on_exit(fn ->
        restore_env(:engram, :key_provider, prev_provider)
        restore_env(:engram, :aws_kms_client, prev_client)
      end)

      :ok
    end

    defp restore_env(app, key, nil), do: Application.delete_env(app, key)
    defp restore_env(app, key, value), do: Application.put_env(app, key, value)

    test "raises when boot_check (DescribeKey) fails" do
      Repo.insert_all("system_canaries", [
        %{
          wrapped_dek: <<0xAA, 0x01, :crypto.strong_rand_bytes(48)::binary>>,
          dek_sha256: :crypto.hash(:sha256, <<0>>),
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
      ])

      expect(Engram.AwsKmsMock, :describe_key, fn -> {:error, :access_denied} end)

      assert_raise RuntimeError, ~r/describe_key|boot_check/i, fn ->
        Engram.Crypto.BootCanary.verify!()
      end
    end

    test "tags :ok telemetry with provider: :aws_kms when DEK round-trips" do
      dek = :crypto.strong_rand_bytes(32)
      sha = :crypto.hash(:sha256, dek)
      blob = <<0xAA, 0x01, :crypto.strong_rand_bytes(48)::binary>>

      Repo.insert_all("system_canaries", [
        %{
          wrapped_dek: blob,
          dek_sha256: sha,
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
      ])

      expect(Engram.AwsKmsMock, :describe_key, fn -> :ok end)
      expect(Engram.AwsKmsMock, :decrypt, fn _ct, _ctx -> {:ok, dek} end)

      :telemetry.attach(
        "boot-canary-aws-ok",
        [:engram, :crypto, :boot_canary],
        fn _n, _m, meta, _ -> send(self(), {:canary, meta}) end,
        nil
      )

      try do
        assert :ok = Engram.Crypto.BootCanary.verify!()
        assert_received {:canary, %{status: :ok, provider: :aws_kms}}
      after
        :telemetry.detach("boot-canary-aws-ok")
      end
    end
  end
end
