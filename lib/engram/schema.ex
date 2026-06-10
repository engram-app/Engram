defmodule Engram.Schema do
  @moduledoc """
  Base schema module enforcing project-wide PK conventions.

  Sets `@primary_key {:id, Ecto.UUID, autogenerate: false}` and
  `@foreign_key_type Ecto.UUID` so domain schemas don't redeclare these.

  PK values come from one of two sources:

  * Postgres column DEFAULT `uuidv7()` — server mints on INSERT.
  * App-side mint via `:uuidv7` hex lib at the context boundary
    (used by `Engram.Notes` to make the id available before round-trip).

  Oban tables and `schema_migrations` do not use this macro; they
  remain bigint.
  """
  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema
      @primary_key {:id, Ecto.UUID, autogenerate: false}
      @foreign_key_type Ecto.UUID
    end
  end
end
