defmodule Facturx.Extract do
  @moduledoc """
  Extract the embedded CII XML from a Factur-X / ZUGFeRD PDF (pure Elixir).

  Locates the embedded file referenced by the PDF's `/Filespec`
  (`/AFRelationship /Data`), decodes its `FlateDecode` stream, and reports the
  detected profile.

  Reads both cross-reference forms: the classic table, and the PDF 1.5+ stream
  with its objects compressed into object streams. The index is built by scanning
  for `N G obj` and then expanding every object stream — never from the
  cross-reference table, which an incremental update leaves pointing at the
  objects the update replaced.

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
    objects = Facturx.PDF.object_index(pdf)

    result =
      with {:ok, filespec} <- find_filespec(objects),
           {:ok, filename} <- embedded_filename(filespec),
           {:ok, ref} <- embedded_ref(filespec),
           {:ok, stream_obj} <- resolve(objects, ref),
           {:ok, raw} <- Facturx.PDF.stream_bytes(stream_obj),
           {:ok, xml} <- Facturx.PDF.inflate(raw) do
        {:ok,
         %{
           # Detach small results from the multi-MB PDF binary (see moduledoc).
           xml: :binary.copy(xml),
           filename: :binary.copy(filename),
           profile: detect_profile(xml)
         }}
      end

    result
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
