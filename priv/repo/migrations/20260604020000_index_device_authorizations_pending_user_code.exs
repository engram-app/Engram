defmodule Engram.Repo.Migrations.IndexDeviceAuthorizationsPendingUserCode do
  use Ecto.Migration

  # squawk-ignore-file — `device_authorizations` is short-lived (5-min TTL)
  # and rarely accessed; non-concurrent index creation blocks for ~ms in the
  # worst case. CONCURRENTLY adds operational complexity (no transaction,
  # disable_ddl_transaction true) that the table doesn't need.
  #
  # `DeviceFlow.suggested_vault_name/2` and `authorize_device/3` both hot-path
  # filter device_authorizations by `user_code = ? AND status = 'pending' AND
  # expires_at > NOW()`. The existing unique index on user_code alone helps
  # the lookup, but the status filter still scans every row that ever used
  # that code (rare in practice but a partial index makes it free).
  # Restricted to status='pending' since that's the only filter the hot path
  # uses; expired rows get swept by `cleanup_expired/0` anyway.

  def up do
    create index(:device_authorizations, [:user_code],
             where: "status = 'pending'",
             name: :device_authorizations_pending_user_code_index
           )
  end

  def down do
    drop index(:device_authorizations, [:user_code],
           name: :device_authorizations_pending_user_code_index
         )
  end
end
