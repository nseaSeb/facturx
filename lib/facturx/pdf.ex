defmodule Facturx.PDF do
  @moduledoc false
  # Byte-level lexicon shared by `Facturx.Embed` (writer) and `Facturx.Extract`
  # (reader).
  #
  # Neither module builds an object model: both work on the raw file. So the few
  # rules that decide where a stream stops and where a dictionary closes have to
  # be the same rules on both sides. They were written twice, and the two copies
  # then had to be fixed twice for the same bug — hence this module.
  #
  # Nothing here raises. A malformed file is an input, not a programming error,
  # and both callers promise `{:error, term()}`.

  # A direct `/Length N`, never the indirect `/Length N G R` form. The `\b`
  # matters: without it the engine backtracks into the digits when the lookahead
  # fires, so `/Length 120 0 R` captures "12" instead of failing.
  @direct_length ~r{/Length\s+(\d+)\b(?!\s*\d+\s+R)}

  # `/Encrypt` is only ever an indirect reference or an inline dictionary.
  # Requiring one of the two shapes keeps the word itself — in a title, in a
  # stream — from being read as encryption.
  @encrypt ~r{/Encrypt\s*(?:\d+\s+\d+\s+R|<<)}

  @doc """
  The declared length of the stream starting at `data_start`, from `dict`.

  `/Length` is where a stream actually stops, and it is authoritative: the
  `endstream` keyword cannot be found by scanning, because stream data does
  contain those bytes — a deflate stored block copies its input verbatim, an
  uncompressed XMP packet can simply mention the word. Guessing at the EOL that
  precedes `endstream` is wrong too: it eats a real byte as soon as the data
  ends with CR or LF, which for a deflate stream is about one document in 256
  (the last byte being the low byte of the adler32), and what comes out no
  longer inflates.

  The length is still checked before being used — it must land on `endstream`
  with nothing but an EOL in between. Producers do get it wrong, and a wrong
  length would silently truncate where a scan would have worked.
  """
  @spec stream_length(binary(), binary(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | :error
  def stream_length(dict, bin, data_start) do
    with [_, n] <- Regex.run(@direct_length, dict),
         len = String.to_integer(n),
         true <- data_start + len <= byte_size(bin),
         tail = binary_part(bin, data_start + len, byte_size(bin) - data_start - len),
         true <- eol_then_endstream?(tail) do
      {:ok, len}
    else
      _ -> :error
    end
  end

  defp eol_then_endstream?(<<"\r\n", rest::binary>>), do: String.starts_with?(rest, "endstream")

  defp eol_then_endstream?(<<c, rest::binary>>) when c in [?\r, ?\n],
    do: String.starts_with?(rest, "endstream")

  defp eol_then_endstream?(rest), do: String.starts_with?(rest, "endstream")

  @doc """
  The balanced `<< … >>` dictionary at or after `pos`.

  Scans only as far as the dictionary closes, not to the end of the file. Like
  every other reader here it does not tokenise, so a `<<` or `>>` inside a
  string literal would still confuse it — no producer of PDF/A has been seen to
  emit one.
  """
  @spec balanced_dict(binary(), non_neg_integer()) ::
          {:ok, binary()} | {:error, :dictionary_not_found | :malformed_dictionary}
  def balanced_dict(bin, pos) do
    case :binary.match(bin, "<<", scope: {pos, byte_size(bin) - pos}) do
      :nomatch -> {:error, :dictionary_not_found}
      {open, _} -> close_dict(bin, open + 2, 1, open)
    end
  end

  defp close_dict(bin, cursor, depth, open) do
    case :binary.match(bin, ["<<", ">>"], scope: {cursor, byte_size(bin) - cursor}) do
      :nomatch ->
        {:error, :malformed_dictionary}

      {p, _} ->
        case {binary_part(bin, p, 2), depth} do
          {"<<", _} -> close_dict(bin, p + 2, depth + 1, open)
          {">>", 1} -> {:ok, binary_part(bin, open, p + 2 - open)}
          {">>", _} -> close_dict(bin, p + 2, depth - 1, open)
        end
    end
  end

  @doc """
  Whether `pdf` declares encryption.

  Neither module can read an encrypted file, and neither used to notice: the
  outcome was a failed inflate or meaningless bytes rather than an error.
  """
  @spec encrypted?(binary()) :: boolean()
  def encrypted?(pdf), do: Regex.match?(@encrypt, pdf)

  @doc "`stream` must be followed by CRLF or LF; the data begins after it."
  @spec skip_eol(binary(), non_neg_integer()) :: non_neg_integer()
  def skip_eol(bin, pos) do
    case bin do
      <<_::binary-size(pos), "\r\n", _::binary>> -> pos + 2
      <<_::binary-size(pos), "\n", _::binary>> -> pos + 1
      <<_::binary-size(pos), "\r", _::binary>> -> pos + 1
      _ -> pos
    end
  end

  @doc """
  `e`, less the EOL that precedes it, when there is one.

  Only for the fallback path, where no usable `/Length` said where the stream
  stopped: this is the guess that costs a byte once in 256.
  """
  @spec strip_trailing_eol(binary(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def strip_trailing_eol(bin, start, e) when e - 2 >= start do
    case binary_part(bin, e - 2, 2) do
      "\r\n" -> e - 2
      <<_, c>> when c in [?\r, ?\n] -> e - 1
      _ -> e
    end
  end

  def strip_trailing_eol(_bin, _start, e), do: e
end
