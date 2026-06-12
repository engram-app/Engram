defmodule Engram.Schema do
  @moduledoc """
  Base schema module enforcing project-wide PK conventions.

  Sets `@primary_key {:id, Ecto.UUID, autogenerate: false, read_after_writes: true}`
  and `@foreign_key_type Ecto.UUID` so domain schemas don't redeclare these.

  PK values come from one of two sources:

  * Postgres column DEFAULT `uuidv7()` — server mints on INSERT.
    `read_after_writes: true` causes Ecto to add `RETURNING id` so the
    struct surfaces the server-minted value to the caller.
  * App-side mint via `:uuidv7` hex lib at the context boundary
    (used by `Engram.Notes` to make the id available before round-trip).
    The explicit `id` in the changeset short-circuits the server default;
    `RETURNING id` still echoes the same value back, which is harmless.

  Oban tables and `schema_migrations` do not use this macro; they
  remain bigint.
  """
  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema
      @primary_key {:id, Ecto.UUID, autogenerate: false, read_after_writes: true}
      @foreign_key_type Ecto.UUID
    end
  end
end
