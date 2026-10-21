defmodule Engram.Notes.KeyAliases do
  @moduledoc """
  Localized KEY names for the named frontmatter fields: `種類: 会議` reads as
  `type: 会議`, `説明:` as `description:`. One static map for every shipped
  locale, whatever the user's UI language.

  The names are not written here. They are translategemma output from the
  web app's pipeline (`frontend/src/i18n/frontmatter-keys.ts` holds the
  English source keys; `bun run i18n:translate` writes
  `frontend/src/i18n/locale/keys/<locale>.json`), read at compile time, so
  the backend and the web app resolve an alias from one generated source.
  The Dockerfile's builder stage copies that directory for this reason.

  Matching folds NFKC then lower case on both sides (`OkfFields.normalize_type/1`),
  so `ｔｙｐｅ`, `Type` and `種類` are all `type`. A localized name equal to
  an English key (`status`, `resource`, `title`, ...) is ignored, so it can
  never point an English key at another field. A word two fields share in
  ONE locale (it `scadenza`) is dropped for both there; English keys always
  work. A word shared across locales goes to the first locale in order
  (`Engram.I18n.locales/0`), then field order.

  The table is versioned by a content hash (`version/0`); a regenerated
  catalog heals existing notes (`Engram.DataMigrations.KeyAliases`).

  `tags` has no aliases: Obsidian reads only `tags` as tags, and the tag
  index follows it.

  **Collisions** (`canonicalize/1`): when a note has several keys for one
  field (`type` and `種類`, or two aliases), the English key as written
  wins, then any other spelling of it (`Type`, `ｔｙｐｅ`), then the alias
  of the first locale in order. Every loser is KEPT under its key as
  written, so a losing alias becomes a user-added key (the catalog lists it,
  nothing is invisible); a losing casing of the English key folds as
  before (`FrontmatterAttrs` skips it).
  """

  alias Engram.Notes.OkfFields

  @fields ~w(type status author reviewed_by source project created updated reviewed expires
             due priority description)

  # English names a named field already answers to. Mirrors ENGLISH in
  # frontmatter-keys.ts.
  @english MapSet.new(
             @fields ++
               ~w(tags resource sources date timestamp modified stale_after generated verified
                  title aliases)
           )

  @dir Path.expand("../../../frontend/src/i18n/locale/keys", __DIR__)

  # Per locale (in order), per field, its names. A LIST: the shape and the
  # matcher take synonyms; the pipeline ships one word per field.
  @table (for code <- Engram.I18n.locales() -- ["en"] do
            path = Path.join(@dir, "#{code}.json")
            @external_resource path
            catalog =
              if File.exists?(path), do: path |> File.read!() |> Jason.decode!(), else: %{}

            {code, Map.new(@fields, &{&1, catalog |> Map.get(&1) |> List.wrap()})}
          end)

  # Normalized alias => {field, locale rank}. Within one locale a word two
  # fields share (it `scadenza` for expires AND due) is dropped for both:
  # English still works. Across locales the first in order, then field, wins.
  @aliases (for {{_code, names}, rank} <- Enum.with_index(@table), reduce: %{} do
              acc ->
                pairs =
                  for field <- @fields,
                      name <- names[field],
                      is_binary(name),
                      norm = OkfFields.normalize_type(name),
                      not MapSet.member?(@english, norm),
                      uniq: true,
                      do: {norm, field}

                shared =
                  pairs |> Enum.frequencies_by(&elem(&1, 0)) |> Map.filter(&(elem(&1, 1) > 1))

                for {norm, field} <- pairs, not Map.has_key?(shared, norm), reduce: acc do
                  acc -> Map.put_new(acc, norm, {field, rank})
                end
            end)

  # The table's version: a content hash, so a regenerated catalog that moves
  # any alias is a new version and `Engram.DataMigrations.KeyAliases` heals.
  @version (
             <<v::31, _::bitstring>> =
               :crypto.hash(:sha256, :erlang.term_to_binary(Enum.sort(@aliases)))

             v
           )

  @doc "The alias table's version (stamped on `notes.key_alias_version`)."
  def version, do: @version

  # ponytail: plain, Capitalized and UPPER spellings only; a fullwidth or
  # mIxEd-case key misses the prefilter (its chunk lead line), nothing else.
  @markers Map.new(@fields, fn field ->
             names = [field | for({norm, {^field, _}} <- @aliases, do: norm)]

             {field,
              names
              |> Enum.flat_map(&[&1, String.capitalize(&1), String.upcase(&1)])
              |> Enum.uniq()}
           end)

  @doc """
  Substrings one of which any usual spelling of `field` contains, so a
  caller can skip the YAML parse of a block that cannot hold it.
  """
  @spec markers(String.t()) :: [String.t()]
  def markers(field), do: Map.fetch!(@markers, field)

  @doc "Every localized alias (normalized) with its English field."
  @spec aliases() :: %{String.t() => String.t()}
  def aliases, do: Map.new(@aliases, fn {norm, {field, _rank}} -> {norm, field} end)

  @doc """
  The named field `key` stands for: its English name in any casing or width,
  or a localized alias. nil for any other key (OKF's English aliases such as
  `resource` included; their callers match them as before).
  """
  @spec canonical(String.t()) :: String.t() | nil
  def canonical(key) when is_binary(key) do
    norm = OkfFields.normalize_type(key)

    cond do
      norm in @fields -> norm
      Map.has_key?(@aliases, norm) -> elem(@aliases[norm], 0)
      true -> nil
    end
  end

  @doc """
  Decoded top-level frontmatter `values` with each named field under its
  English key, per the collision rule in the moduledoc. Every other key is
  untouched.
  """
  @spec canonicalize(%{String.t() => term()}) :: %{String.t() => term()}
  def canonicalize(values) when is_map(values) do
    values
    |> Enum.group_by(fn {key, _value} -> canonical(key) end)
    |> Enum.flat_map(fn
      {nil, pairs} ->
        pairs

      {field, pairs} ->
        [{_winner, value} | losers] = Enum.sort_by(pairs, &rank(field, elem(&1, 0)))
        [{field, value} | losers]
    end)
    |> Map.new()
  end

  defp rank(field, field), do: {0, 0, field}

  defp rank(field, key) do
    case @aliases[OkfFields.normalize_type(key)] do
      {^field, locale} -> {2, locale, key}
      _ -> {1, 0, key}
    end
  end
end
