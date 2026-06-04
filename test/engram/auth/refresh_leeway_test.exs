defmodule Engram.Auth.RefreshLeewayTest do
  use ExUnit.Case, async: true

  alias Engram.Auth.RefreshLeeway

  describe "benign?/2" do
    setup do
      %{now: ~U[2026-06-04 12:00:00Z]}
    end

    test "true when revoked_at is now (just-rotated)", %{now: now} do
      assert RefreshLeeway.benign?(now, now)
    end

    test "true at the exact cutoff boundary (revoked_at = now - leeway)", %{now: now} do
      revoked = DateTime.add(now, -RefreshLeeway.seconds(), :second)
      assert RefreshLeeway.benign?(revoked, now)
    end

    test "false just outside the leeway window", %{now: now} do
      revoked = DateTime.add(now, -RefreshLeeway.seconds() - 1, :second)
      refute RefreshLeeway.benign?(revoked, now)
    end

    test "false at the epoch sentinel used for admin/breach revocations", %{now: now} do
      refute RefreshLeeway.benign?(~U[1970-01-01 00:00:00Z], now)
    end
  end
end
