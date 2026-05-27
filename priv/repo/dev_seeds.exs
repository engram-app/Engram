# Dev/staging data seeder.
#
# Populates users, vaults, and notes through the real Engram contexts so the
# encryption layer runs: per-user DEK provisioning, AAD-bound AES-GCM on note
# fields, and the HMAC lookup columns (path/folder/tags/content_hash). Raw SQL
# or CSV imports CANNOT seed these tables — the plaintext content/title/path
# columns were dropped in the phase-B migrations, leaving only ciphertext +
# HMAC columns that are meaningless without going through Engram.Crypto.
#
# Idempotent: users keyed by deterministic external_id (SEED_PREFIX), notes
# keyed by path via upsert_note/3. Re-running updates in place instead of
# duplicating.
#
# Usage (against the local Supabase audit DB):
#
#   DATABASE_URL="postgres://postgres:postgres@127.0.0.1:54322/postgres" \
#   KEY_PROVIDER=local ENCRYPTION_MASTER_KEY="$(openssl rand -base64 32)" \
#   mix run priv/repo/dev_seeds.exs
#
# Tunables (env vars):
#   SEED_USERS           number of users          (default 10)
#   SEED_NOTES_PER_USER  notes per user/vault     (default 200)
#   SEED_PREFIX          external_id/email prefix (default "seed")
#
# Embeddings: the :embed and :reindex Oban queues are paused before inserts so
# no Voyage AI / Qdrant calls fire. The enqueued jobs remain in oban_jobs
# (useful as realistic queue data); they never execute under this script.

alias Engram.{Accounts, Crypto, Notes, Vaults}

defmodule DevSeed do
  @folders ["Projects", "Daily", "Reference", "Archive/2026", "Inbox", "Areas/Health"]
  @tag_pool ~w(elixir phoenix obsidian sync crypto billing infra research idea todo meeting)
  @words ~w(system vault note index search vector embedding query tenant policy
            migration schema encryption pipeline channel worker cache token plan
            limit usage meter audit advisor postgres docker cluster region payload)

  def words(n), do: 1..n |> Enum.map(fn _ -> Enum.random(@words) end) |> Enum.join(" ")

  def paragraph,
    do: 1..(:rand.uniform(4) + 2) |> Enum.map(fn _ -> sentence() end) |> Enum.join(" ")

  defp sentence, do: String.capitalize(words(:rand.uniform(10) + 4)) <> "."

  def folder, do: Enum.random(@folders)

  def note_content(i) do
    tags = Enum.take_random(@tag_pool, :rand.uniform(3))
    frontmatter = "---\ntitle: Seed Note #{i}\ntags: [#{Enum.join(tags, ", ")}]\n---\n\n"
    body = 1..(:rand.uniform(3) + 1) |> Enum.map(fn _ -> paragraph() end) |> Enum.join("\n\n")
    link = "\n\nRelated: [[#{folder()}/note_#{:rand.uniform(max(i, 1))}]]"
    inline_tags = "\n\n" <> Enum.map_join(tags, " ", &("#" <> &1))
    "#{frontmatter}# Seed Note #{i}\n\n#{body}#{link}#{inline_tags}"
  end
end

users_n = String.to_integer(System.get_env("SEED_USERS") || "10")
notes_per = String.to_integer(System.get_env("SEED_NOTES_PER_USER") || "200")
prefix = System.get_env("SEED_PREFIX") || "seed"

# Stop background processing so seeding never reaches out to Voyage AI / Qdrant.
for q <- [:embed, :reindex] do
  try do
    Oban.pause_queue(queue: q)
  rescue
    e -> IO.puts("  warn: could not pause #{q} queue: #{inspect(e)}")
  end
end

IO.puts("Seeding #{users_n} users x #{notes_per} notes (prefix=#{prefix})...")

{users_created, notes_created} =
  Enum.reduce(1..users_n, {0, 0}, fn u, {uc, nc} ->
    ext_id = "#{prefix}_user_#{String.pad_leading(Integer.to_string(u), 4, "0")}"
    email = "#{ext_id}@seed.local"

    {:ok, user} = Accounts.find_or_create_by_external_id(ext_id, %{email: email})
    {:ok, user} = Crypto.ensure_user_dek(user)

    vault =
      case Vaults.create_vault(user, %{name: "#{prefix} vault #{u}"}) do
        {:ok, v} -> v
        {:error, :vault_limit_reached} -> hd(Vaults.list_vaults(user))
      end

    note_count =
      Enum.reduce(1..notes_per, 0, fn n, acc ->
        path = "#{DevSeed.folder()}/note_#{n}.md"

        case Notes.upsert_note(user, vault, %{
               "path" => path,
               "content" => DevSeed.note_content(n),
               "mtime" => System.system_time(:second)
             }) do
          {:ok, _note} -> acc + 1
          {:error, :notes_cap_reached} -> acc
          other -> IO.puts("  note error (#{path}): #{inspect(other)}") && acc
        end
      end)

    if rem(u, 5) == 0, do: IO.puts("  ...#{u}/#{users_n} users done")
    {uc + 1, nc + note_count}
  end)

IO.puts("Done. #{users_created} users, #{notes_created} notes.")
