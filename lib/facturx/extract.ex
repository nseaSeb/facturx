defmodule Facturx.Extract do
  @moduledoc """
  Extract the embedded CII XML from a Factur-X / ZUGFeRD PDF (pure Elixir).

  Locates the embedded file referenced by the PDF's `/Filespec`
  (`/AFRelationship /Data`), decodes its `FlateDecode` stream, and reports the
  detected profile.

  Supports classic cross-reference table PDFs (the shape emitted by the common
  Typst + factur-x toolchains). Object streams / cross-reference streams are not
  yet handled — see `docs/adr/0001-perimetre-et-architecture.md`.

  Unlike `Facturx.Embed`, this module does not require its input to be PDF/A, and
  does not check: reading an attachment cannot damage the document, so refusing a
  file it can in fact read would only be in the caller's way. The library will
  therefore read from PDFs it would decline to write to.

  ## Memory note (BEAM refc binaries)

  A PDF is a large binary (> 64 bytes → refc binary). Slicing it yields
  sub-binaries that retain the *whole* PDF. Everything we return — the XML and
  the filename — is `:binary.copy/1`-ed so the multi-MB PDF can be collected.
  """

  @typedoc "Result of a successful extraction."
  @type result :: %{
          xml: binary(),
          profile: Facturx.profile() | nil,
          filename: String.t()
        }

  # Known filenames for the embedded CII/Order-X payload.
  @known_names ~w(factur-x.xml zugferd-invoice.xml order-x.xml)

  @doc "Extract the embedded CII XML and metadata from `pdf`."
  @spec extract(binary()) :: {:ok, result()} | {:error, term()}
  def extract(pdf) when is_binary(pdf) do
    if Facturx.PDF.encrypted?(pdf), do: {:error, :encrypted_pdf_unsupported}, else: read(pdf)
  rescue
    # The guard above reads the trailer, so it is inside the contract too: this
    # function promises `{:error, term()}` for any binary, and the promise cannot
    # start one call later. Same narrow list as `Facturx.Embed.embed/3` — these
    # three are what slicing and matching on a malformed binary raise, and a
    # FunctionClauseError from a defect here is a bug to see, not an input error.
    e in [ArgumentError, MatchError, ErlangError] -> {:error, e}
  end

  # Only the strings and the stream *data* of an encrypted PDF are encrypted:
  # the object structure, `/EF`, `/AFRelationship` and the object numbers are
  # all still plaintext. So the pipeline below runs to completion on such a file
  # and hands back bytes that decrypt to nothing — which is exactly why the
  # check above is a gate and not, as it first was, a branch on the
  # `:no_embedded_file` result.
  defp read(pdf) do
    objects = index_objects(pdf)

    result =
      with {:ok, filespec} <- find_filespec(objects),
           {:ok, filename} <- embedded_filename(filespec),
           {:ok, ref} <- embedded_ref(filespec),
           {:ok, stream_obj} <- resolve(objects, ref),
           {:ok, raw} <- stream_bytes(stream_obj),
           {:ok, xml} <- inflate(raw) do
        {:ok,
         %{
           # Detach small results from the multi-MB PDF binary (see moduledoc).
           xml: :binary.copy(xml),
           filename: :binary.copy(filename),
           profile: detect_profile(xml)
         }}
      end

    # Having found nothing is not the same as there being nothing: a PDF using
    # object/xref streams may well carry an attachment this module cannot reach.
    # Say which it is rather than claim the PDF has none.
    case result do
      {:error, :no_embedded_file} ->
        if object_streams?(pdf), do: {:error, :object_streams_unsupported}, else: result

      other ->
        other
    end
  end

  defp object_streams?(pdf) do
    String.contains?(pdf, "/ObjStm") or Regex.match?(~r|/Type\s*/XRef|, pdf)
  end

  # --- object index (classic xref, brute-force recovery) -------------------

  # Map {num, gen} => object body (bytes between `obj` and `endobj`). Scanning
  # for `N G obj` rather than trusting the xref table survives incremental
  # updates; a later definition of the same object wins.
  defp index_objects(pdf) do
    Regex.scan(~r/(\d+)\s+(\d+)\s+obj\b/, pdf, return: :index)
    |> Enum.reduce(%{}, fn [{s, len} | _], acc ->
      header = binary_part(pdf, s, len)
      [num, gen] = header |> String.split() |> Enum.take(2) |> Enum.map(&String.to_integer/1)
      body_start = s + len

      Map.put(acc, {num, gen}, object_body(pdf, body_start))
    end)
  end

  # The index maps each object to `{body, :delimited | :truncated}`. The flag
  # matters to `scan_to_endstream/3`: taking the *last* `endstream` is right
  # within a delimited object, and wrong for one that runs to EOF, where it
  # would slice the whole tail of the file.

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

  defp resolve(objects, {num, gen}) do
    case Map.get(objects, {num, gen}) || Map.get(objects, {num, 0}) do
      nil -> {:error, {:missing_object, num, gen}}
      entry -> {:ok, entry}
    end
  end

  # --- locating the embedded file ------------------------------------------

  # The Filespec dict carries /AFRelationship and /EF. Pick the one whose name
  # is a known Factur-X payload, else the first /EF-bearing dict.
  defp find_filespec(objects) do
    candidates =
      objects
      |> Map.values()
      |> Enum.map(&elem(&1, 0))
      |> Enum.filter(&(String.contains?(&1, "/EF") and String.contains?(&1, "/AFRelationship")))

    preferred =
      Enum.find(candidates, fn body ->
        case embedded_filename(body) do
          {:ok, name} -> name in @known_names
          _ -> false
        end
      end)

    case preferred || List.first(candidates) do
      nil -> {:error, :no_embedded_file}
      body -> {:ok, body}
    end
  end

  defp embedded_filename(filespec) do
    # Prefer /UF (unicode) then /F, both PDF literal strings.
    case Regex.run(~r/\/UF\s*\(((?:\\.|[^\\()])*)\)/, filespec) ||
           Regex.run(~r/\/F\s*\(((?:\\.|[^\\()])*)\)/, filespec) do
      [_, raw] -> {:ok, unescape_pdf_string(raw)}
      _ -> {:error, :no_filename}
    end
  end

  # /EF << /F N 0 R /UF M 0 R >> — the indirect ref to the embedded stream.
  defp embedded_ref(filespec) do
    with [_, ef] <- Regex.run(~r/\/EF\s*<<(.*?)>>/s, filespec),
         [_, num, gen] <-
           Regex.run(~r/\/(?:UF|F)\s+(\d+)\s+(\d+)\s+R/, ef) ||
             Regex.run(~r/(\d+)\s+(\d+)\s+R/, ef) do
      {:ok, {String.to_integer(num), String.to_integer(gen)}}
    else
      _ -> {:error, :no_ef_ref}
    end
  end

  # --- stream decoding ------------------------------------------------------

  defp stream_bytes({obj, delimited}) do
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
  defp inflate(data) do
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

  # --- helpers --------------------------------------------------------------

  defp detect_profile(xml), do: Facturx.Profile.detect(xml)

  # Decode PDF literal-string escapes: \n \r \t \b \f \( \) \\ and \ddd octal.
  defp unescape_pdf_string(raw), do: unescape(raw, [])

  defp unescape(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp unescape(<<"\\", d1, d2, d3, rest::binary>>, acc)
       when d1 in ?0..?7 and d2 in ?0..?7 and d3 in ?0..?7 do
    unescape(rest, [(d1 - ?0) * 64 + (d2 - ?0) * 8 + (d3 - ?0) | acc])
  end

  defp unescape(<<"\\", c, rest::binary>>, acc) do
    mapped =
      case c do
        ?n -> ?\n
        ?r -> ?\r
        ?t -> ?\t
        ?b -> ?\b
        ?f -> ?\f
        other -> other
      end

    unescape(rest, [mapped | acc])
  end

  defp unescape(<<c, rest::binary>>, acc), do: unescape(rest, [c | acc])
end
