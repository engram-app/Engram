defmodule Engram.Attachments.Uploads do
  @moduledoc """
  Chunked (multipart) attachment uploads. The part-size contract lives here so
  the channel can advertise it; the upload lifecycle arrives in a later task.
  """

  # 8 MiB: above S3's 5 MiB non-final-part minimum, small enough to retry cheaply.
  @part_size 8_388_608

  @spec part_size() :: pos_integer()
  def part_size, do: @part_size
end
