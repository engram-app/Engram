# Phase 3, on OLD (J), on K's schema: a read of the dropped column through
# J's own repo. Green: it must fail with undefined_column (the column is
# gone). Fault hash-read: the same read in an unsupervised process, uncaught,
# as a J code path that still read the column would be: its crash report is
# an [error] line the workflow's error scan must catch.
sql = "SELECT full_path_hmac FROM folders LIMIT 1"

if fault == "hash-read" do
  pid = spawn(fn -> Engram.Repo.query!(sql) end)
  ref = Process.monitor(pid)
  receive do
    {:DOWN, ^ref, _, _, :normal} -> IO.puts("HASH_READ_PROCESS=normal")
    {:DOWN, ^ref, _, _, _reason} -> IO.puts("HASH_READ_PROCESS=crashed")
  after
    10_000 -> IO.puts("HASH_READ_PROCESS=timeout")
  end
else
  r =
    case Engram.Repo.query(sql) do
      {:ok, _} -> "ok"
      {:error, %Postgrex.Error{postgres: %{code: code}}} -> to_string(code)
      {:error, other} -> inspect(other)
    end

  IO.puts("HASH_READ=#{r}")
end
