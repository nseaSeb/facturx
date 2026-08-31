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

  Only the document's own trailer is read, in whichever of the two forms it
  takes: the dictionary after the last `trailer` keyword, or — for a PDF 1.5+
  file, which has no such keyword — the cross-reference stream that `startxref`
  points at, whose dictionary carries the same keys.

  Both, and nothing else. `/Encrypt` is meaningful in a trailer and nowhere else,
  so scanning the whole file would refuse documents that merely contain those
  bytes: an uncompressed XMP packet quoting the PDF spec, a content stream. And
  the *last* one is the document's — earlier ones belong to revisions this file
  has superseded, so a file decrypted by an incremental update still carries an
  `/Encrypt` trailer that no longer applies, and honouring it would refuse a file
  that is perfectly readable.
  """
  @spec encrypted?(binary()) :: boolean()
  def encrypted?(pdf) do
    Enum.any?(trailer_dicts(pdf), &Regex.match?(@encrypt, &1))
  end

  defp trailer_dicts(pdf) do
    positions =
      [last_position(pdf, "trailer"), startxref_offset(pdf)]
      |> Enum.reject(&(is_nil(&1) or &1 >= byte_size(pdf)))

    for pos <- positions, {:ok, dict} <- [balanced_dict(pdf, pos)], do: dict
  end

  defp last_position(pdf, needle) do
    case pdf |> :binary.matches(needle) |> List.last() do
      {pos, _} -> pos
      nil -> nil
    end
  end

  # Where `startxref` points: the cross-reference stream object in a PDF 1.5+
  # file, and the `xref` table in a classic one — where the dictionary that
  # follows is the trailer, so reading it changes nothing.
  defp startxref_offset(pdf) do
    case Regex.scan(~r/startxref\s+(\d+)/, pdf) |> List.last() do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end

  @doc """
  Every object in `pdf`, as `%{{number, generation} => {body, :delimited | :truncated}}`.

  Two sources, merged. First a scan for `N G obj` — rather than the
  cross-reference table, because a scan survives an incremental update, where the
  table of the previous revision still points at the object the update replaced.
  Then the contents of every object stream, since a PDF 1.5 file keeps most of
  its dictionaries compressed inside one and they have no `N G obj` header of
  their own.

  A top-level definition wins over a compressed one carrying the same number, and
  a later object stream wins over an earlier one: that is what an incremental
  update means, and it is the rule the cross-reference table would have applied.
  """
  @spec object_index(binary()) ::
          %{{non_neg_integer(), non_neg_integer()} => {binary(), :delimited | :truncated}}

  def object_index(pdf) do
    scanned = scan_objects(pdf)
    top_level = Map.new(scanned, fn {key, entry} -> {key, entry} end)

    scanned
    |> Enum.filter(fn {_key, {body, _}} -> String.contains?(body, "/ObjStm") end)
    |> Enum.map(fn {_key, entry} -> expand_object_stream(entry) end)
    |> Enum.reject(&(&1 == :error))
    |> Enum.reduce(%{}, &Map.merge(&2, &1))
    |> Map.merge(top_level)
  end

  # An object stream holds `/N` objects: a header of `number offset` pairs, then
  # the objects themselves, the first at `/First`. Offsets are relative to
  # `/First`, and the last object runs to the end of the data.
  defp expand_object_stream({body, _} = entry) do
    with {:ok, dict} <- object_stream_dict(body),
         [_, n] <- Regex.run(~r{/N\s+(\d+)}, dict),
         [_, first] <- Regex.run(~r{/First\s+(\d+)}, dict),
         {:ok, raw} <- stream_bytes(entry),
         {:ok, data} <- maybe_inflate(dict, raw) do
      count = String.to_integer(n)
      first = String.to_integer(first)

      case pairs(data, count, first) do
        :error -> :error
        pairs -> slice(data, pairs, first)
      end
    else
      _ -> :error
    end
  end

  defp object_stream_dict(body) do
    case :binary.match(body, "stream") do
      {s, _} -> {:ok, binary_part(body, 0, s)}
      :nomatch -> :error
    end
  end

  defp maybe_inflate(dict, raw) do
    if String.contains?(dict, "/FlateDecode"), do: inflate(raw), else: {:ok, raw}
  end

  defp pairs(data, count, first) when byte_size(data) >= first do
    numbers =
      data
      |> binary_part(0, first)
      |> String.split()
      |> Enum.map(&Integer.parse/1)

    if Enum.any?(numbers, &(&1 == :error)) or length(numbers) < count * 2 do
      :error
    else
      numbers
      |> Enum.map(&elem(&1, 0))
      |> Enum.take(count * 2)
      |> Enum.chunk_every(2)
      |> Enum.map(fn [number, offset] -> {number, offset} end)
    end
  end

  defp pairs(_data, _count, _first), do: :error

  defp slice(data, pairs, first) do
    stops = pairs |> Enum.drop(1) |> Enum.map(&elem(&1, 1))
    stops = stops ++ [byte_size(data) - first]

    pairs
    |> Enum.zip(stops)
    |> Enum.reduce(%{}, fn {{number, offset}, stop}, acc ->
      start = first + offset
      length = stop - offset

      if start >= 0 and length >= 0 and start + length <= byte_size(data) do
        # A compressed object has no `endobj`, so its extent is exactly what the
        # header says: delimited, by construction.
        Map.put(acc, {number, 0}, {binary_part(data, start, length), :delimited})
      else
        acc
      end
    end)
  end

  # Map {num, gen} => object body (bytes between `obj` and `endobj`). Scanning
  # for `N G obj` rather than trusting the xref table survives incremental
  # updates; a later definition of the same object wins.
  # In file order, and a list rather than a map: the order is what makes the
  # merge above deterministic, and positions are never needed again.
  defp scan_objects(pdf) do
    ~r/(\d+)\s+(\d+)\s+obj\b/
    |> Regex.scan(pdf, return: :index)
    |> Enum.map(fn [{s, len} | _] ->
      [num, gen] =
        pdf
        |> binary_part(s, len)
        |> String.split()
        |> Enum.take(2)
        |> Enum.map(&String.to_integer/1)

      {{num, gen}, object_body(pdf, s + len)}
    end)
  end

  # Bytes from `body_start` to the object's `endobj`.
  #
  # Not simply the first `endobj`: a compressed stream is arbitrary bytes, and
  # deflate output contains the literal "endobj" or "endstream" often enough to
  # matter (a stored block copies its input verbatim). So when the object holds
  # a stream whose `/Length` is direct, the search resumes past the stream data,
  # where a keyword can only be the real one.
  defp object_body(pdf, body_start) do
    rest = binary_part(pdf, body_start, byte_size(pdf) - body_start)

    case :binary.match(rest, "endobj") do
      :nomatch ->
        {rest, :truncated}

      {naive_end, _} ->
        from = stream_data_end(rest, naive_end)

        case :binary.match(rest, "endobj", scope: {from, byte_size(rest) - from}) do
          {e, _} -> {binary_part(rest, 0, e), :delimited}
          :nomatch -> {binary_part(rest, 0, naive_end), :delimited}
        end
    end
  end

  # Offset just past the stream data of `obj`, or 0 when there is nothing to
  # skip — no `stream` keyword before `naive_end`, or no usable `/Length` to say
  # where the data stops.
  #
  # The `scope:` is not an optimisation detail. `obj` runs to the end of the
  # file, so an unbounded search would scan on to the *next* object's stream, or
  # to EOF for a file whose streams all sit at the front — once per object,
  # making the index quadratic in the file size.
  defp stream_data_end(obj, naive_end) do
    with {s, _} <- :binary.match(obj, "stream", scope: {0, naive_end}),
         data_start = Facturx.PDF.skip_eol(obj, s + 6),
         {:ok, len} <- Facturx.PDF.stream_length(binary_part(obj, 0, s), obj, data_start) do
      data_start + len
    else
      _ -> 0
    end
  end

  def stream_bytes({obj, delimited}) do
    case :binary.match(obj, "stream") do
      :nomatch ->
        {:error, :no_stream}

      {s, _} ->
        data_start = Facturx.PDF.skip_eol(obj, s + 6)

        case Facturx.PDF.stream_length(binary_part(obj, 0, s), obj, data_start) do
          {:ok, len} -> {:ok, binary_part(obj, data_start, len)}
          :error -> scan_to_endstream(obj, data_start, delimited)
        end
    end
  end

  # No usable `/Length`: fall back to scanning, and take the **last**
  # `endstream` of the object rather than the first — an earlier one is data.
  #
  # Only within a *delimited* object, though. A truncated one runs to the end of
  # the file, so its "last endstream" is the file's, and the slice would span
  # every object after this one — megabytes copied to fail at inflate. There,
  # the first occurrence is the only bounded guess left.
  defp scan_to_endstream(obj, data_start, delimited) do
    scope = {data_start, byte_size(obj) - data_start}
    matches = :binary.matches(obj, "endstream", scope: scope)

    case if(delimited == :delimited, do: List.last(matches), else: List.first(matches)) do
      nil ->
        {:error, :no_stream}

      {e, _} ->
        stop = Facturx.PDF.strip_trailing_eol(obj, data_start, e)
        {:ok, binary_part(obj, data_start, stop - data_start)}
    end
  end

  # PDF FlateDecode is zlib (RFC 1950); fall back to raw deflate if needed.
  def inflate(data) do
    case safe(fn -> :zlib.uncompress(data) end) do
      {:ok, bin} -> {:ok, bin}
      :error -> raw_inflate(data)
    end
  end

  defp safe(fun) do
    {:ok, fun.()}
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp raw_inflate(data) do
    z = :zlib.open()

    try do
      :zlib.inflateInit(z, -15)
      {:ok, IO.iodata_to_binary(:zlib.inflate(z, data))}
    rescue
      _ -> {:error, :inflate_failed}
    catch
      _, _ -> {:error, :inflate_failed}
    after
      :zlib.close(z)
    end
  end

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
