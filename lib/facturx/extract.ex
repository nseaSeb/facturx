defmodule Facturx.Extract do
  @moduledoc """
  Extract the embedded CII XML from a Factur-X / ZUGFeRD PDF (pure Elixir).

  Locates the embedded file referenced by the PDF's `/Filespec`
  (`/AFRelationship /Data`), decodes its `FlateDecode` stream, and reports the
  detected profile.

  Supports classic cross-reference table PDFs (the shape emitted by the common
  Typst + factur-x toolchains). Object streams / cross-reference streams are not
  yet handled — see `docs/adr/0001-perimetre-et-architecture.md`.

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

    # If we found nothing but the PDF uses object/xref streams, say so plainly
    # rather than claiming there is no attachment (it may just be out of reach).
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

      body =
        case :binary.match(pdf, "endobj", scope: {body_start, byte_size(pdf) - body_start}) do
          {e, _} -> binary_part(pdf, body_start, e - body_start)
          :nomatch -> binary_part(pdf, body_start, byte_size(pdf) - body_start)
        end

      Map.put(acc, {num, gen}, body)
    end)
  end

  defp resolve(objects, {num, gen}) do
    case Map.get(objects, {num, gen}) || Map.get(objects, {num, 0}) do
      nil -> {:error, {:missing_object, num, gen}}
      body -> {:ok, body}
    end
  end

  # --- locating the embedded file ------------------------------------------

  # The Filespec dict carries /AFRelationship and /EF. Pick the one whose name
  # is a known Factur-X payload, else the first /EF-bearing dict.
  defp find_filespec(objects) do
    candidates =
      objects
      |> Map.values()
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

  defp stream_bytes(obj) do
    with {s, _} <- :binary.match(obj, "stream"),
         data_start = skip_eol(obj, s + 6),
         {e, _} <-
           :binary.match(obj, "endstream", scope: {data_start, byte_size(obj) - data_start}) do
      {:ok, stream_data(obj, binary_part(obj, 0, s), data_start, e)}
    else
      _ -> {:error, :no_stream}
    end
  end

  # Prefer `/Length`, which is where the stream actually stops. Guessing instead
  # at the EOL that precedes `endstream` eats a real byte as soon as the data
  # itself ends with CR or LF — for a deflate stream that is roughly one
  # document in 256, the last byte being the low byte of the adler32, and what
  # comes out no longer inflates.
  #
  # A `/Length` is only taken once it lands on `endstream` with nothing but an
  # EOL in between: producers do get it wrong, and a wrong length would silently
  # truncate where the scan would have worked.
  defp stream_data(obj, dict, data_start, e) do
    # The `\b` matters: without it the engine backtracks into the digits when
    # the lookahead fires, so `/Length 120 0 R` captures "12" instead of failing.
    with [_, n] <- Regex.run(~r{/Length\s+(\d+)\b(?!\s*\d+\s+R)}, dict),
         len = String.to_integer(n),
         true <- len <= e - data_start,
         true <-
           binary_part(obj, data_start + len, e - data_start - len) in ["", "\n", "\r\n", "\r"] do
      binary_part(obj, data_start, len)
    else
      _ -> binary_part(obj, data_start, strip_trailing_eol(obj, data_start, e) - data_start)
    end
  end

  # `stream` must be followed by CRLF or LF; data begins after it.
  defp skip_eol(bin, pos) do
    case bin do
      <<_::binary-size(pos), "\r\n", _::binary>> -> pos + 2
      <<_::binary-size(pos), "\n", _::binary>> -> pos + 1
      <<_::binary-size(pos), "\r", _::binary>> -> pos + 1
      _ -> pos
    end
  end

  defp strip_trailing_eol(bin, start, e) when e - 2 >= start do
    case binary_part(bin, e - 2, 2) do
      "\r\n" -> e - 2
      <<_, c>> when c in [?\r, ?\n] -> e - 1
      _ -> e
    end
  end

  defp strip_trailing_eol(_bin, _start, e), do: e

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
