defmodule Facturx.Embed do
  @moduledoc """
  Embed CII XML into an existing PDF/A to produce a Factur-X PDF (pure Elixir).

  Uses an **incremental update**: the original bytes are preserved verbatim
  (fonts, OutputIntent, content streams stay untouched) and only a small set of
  objects is appended — the embedded-file stream, its `/Filespec`, an overridden
  catalog (adds `/AF` + the `EmbeddedFiles` name tree) and an overridden
  `/Metadata` (the promoted XMP).

  ## Input contract

  The base PDF must already be PDF/A-2 or PDF/A-3 (see ADR 0001):

    * PDF/A-3 → embed as-is;
    * PDF/A-2 → embed and promote `pdfaid:part` 2 → 3 (levels A-2 and A-3 share
      identical conformance requirements bar the embedded-file allowance);
    * PDF/A-1 or a non-PDF/A file → refused. No external normaliser (Ghostscript)
      is ever invoked.

  Currently supports classic cross-reference-table PDFs (the Typst output shape).
  """

  alias Facturx.Xmp

  @default_filename "factur-x.xml"

  @doc """
  Embed `xml` into `pdf`.

  Options:

    * `:filename` — embedded file name (default `#{inspect(@default_filename)}`)
    * `:profile`  — Factur-X profile for the XMP `ConformanceLevel`
      (default `:en16931`)
  """
  @spec embed(binary(), binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  def embed(pdf, xml, opts \\ []) when is_binary(pdf) and is_binary(xml) do
    filename = Keyword.get(opts, :filename, @default_filename)
    profile = Keyword.get(opts, :profile, :en16931)

    with :ok <- ensure_classic_xref(pdf),
         {:ok, ctx} <- parse_base(pdf),
         :ok <- check_pdfa_level(ctx.part) do
      build(pdf, xml, ctx, profile, filename)
    end
  end

  # --- input validation -----------------------------------------------------

  defp ensure_classic_xref(pdf) do
    if Regex.match?(~r|/Type\s*/XRef|, pdf) or not String.contains?(pdf, "trailer") do
      {:error, :xref_streams_unsupported}
    else
      :ok
    end
  end

  defp check_pdfa_level(3), do: :ok
  defp check_pdfa_level(2), do: :ok
  defp check_pdfa_level(1), do: {:error, {:unsupported_pdfa, "PDF/A-1"}}
  defp check_pdfa_level(nil), do: {:error, :not_pdfa}
  defp check_pdfa_level(other), do: {:error, {:unsupported_pdfa, other}}

  # --- parse what we need from the base ------------------------------------

  defp parse_base(pdf) do
    with {:ok, trailer} <- trailer_dict(pdf),
         {:ok, root_num} <- capture_int(trailer, ~r/\/Root\s+(\d+)\s+\d+\s+R/),
         {:ok, size} <- capture_int(trailer, ~r/\/Size\s+(\d+)/),
         {:ok, catalog} <- object_dict(pdf, root_num),
         {:ok, meta_num} <- capture_int(catalog, ~r/\/Metadata\s+(\d+)\s+\d+\s+R/),
         {:ok, xmp} <- object_stream(pdf, meta_num),
         {:ok, prev} <- prev_startxref(pdf) do
      {:ok,
       %{
         root_num: root_num,
         size: size,
         catalog: catalog,
         meta_num: meta_num,
         xmp: xmp,
         prev: prev,
         part: pdfa_part(xmp),
         id: capture(trailer, ~r/\/ID\s*(\[.*?\])/s),
         info: capture(trailer, ~r/\/Info\s+(\d+\s+\d+\s+R)/)
       }}
    end
  end

  # Accept both the element form and the compact attribute form of pdfaid:part.
  defp pdfa_part(xmp) do
    case Regex.run(~r/<pdfaid:part>\s*(\d)\s*<\/pdfaid:part>/, xmp) ||
           Regex.run(~r/pdfaid:part\s*=\s*["'](\d)["']/, xmp) do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end

  # --- build the incremental update ----------------------------------------

  defp build(pdf, xml, ctx, profile, filename) do
    emb_num = ctx.size
    fs_num = ctx.size + 1
    new_size = ctx.size + 2

    with {:ok, catalog} <- catalog_obj(ctx.root_num, ctx.catalog, fs_num, filename) do
      xmp = Xmp.promote(ctx.xmp, profile, filename)
      compressed = :zlib.compress(xml)
      moddate = pdf_date(DateTime.utc_now())

      objects = [
        {ctx.meta_num, metadata_obj(ctx.meta_num, xmp)},
        {ctx.root_num, catalog},
        {emb_num, embedded_file_obj(emb_num, compressed, byte_size(xml), moddate)},
        {fs_num, filespec_obj(fs_num, emb_num, filename)}
      ]

      prefix = if String.ends_with?(pdf, "\n"), do: pdf, else: pdf <> "\n"
      {:ok, assemble(prefix, objects, new_size, ctx)}
    end
  end

  # Append each object, tracking byte offsets, then a classic xref section
  # covering exactly the changed/added objects, then the updated trailer.
  defp assemble(prefix, objects, new_size, ctx) do
    {body, offsets} =
      Enum.reduce(objects, {prefix, %{}}, fn {num, bytes}, {acc, offs} ->
        {acc <> bytes, Map.put(offs, num, byte_size(acc))}
      end)

    nums = objects |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    xref_offset = byte_size(body)

    xref =
      xref_subsections(nums, offsets)

    trailer =
      "trailer\n<< /Size #{new_size} /Root #{ctx.root_num} 0 R" <>
        info_entry(ctx.info) <>
        id_entry(ctx.id) <>
        " /Prev #{ctx.prev} >>\nstartxref\n#{xref_offset}\n%%EOF\n"

    body <> xref <> trailer
  end

  # Group the changed object numbers into contiguous xref subsections.
  defp xref_subsections(nums, offsets) do
    runs =
      Enum.chunk_while(
        nums,
        [],
        fn n, acc ->
          case acc do
            [prev | _] when n == prev + 1 -> {:cont, [n | acc]}
            [] -> {:cont, [n]}
            _ -> {:cont, Enum.reverse(acc), [n]}
          end
        end,
        fn acc -> {:cont, Enum.reverse(acc), []} end
      )

    entries =
      Enum.map_join(runs, "", fn run ->
        "#{hd(run)} #{length(run)}\n" <>
          Enum.map_join(run, "", fn n -> xref_entry(Map.fetch!(offsets, n)) end)
      end)

    "xref\n" <> entries
  end

  defp xref_entry(offset) do
    String.pad_leading(Integer.to_string(offset), 10, "0") <> " 00000 n\r\n"
  end

  defp info_entry(nil), do: ""
  defp info_entry(ref), do: " /Info #{ref}"

  defp id_entry(nil), do: ""
  defp id_entry(id), do: " /ID #{id}"

  # --- object bodies --------------------------------------------------------

  defp metadata_obj(num, xmp) do
    "#{num} 0 obj\n<< /Type /Metadata /Subtype /XML /Length #{byte_size(xmp)} >>\nstream\n" <>
      xmp <> "\nendstream\nendobj\n"
  end

  # Merge (never blindly append) our keys into the existing catalog dict, so a
  # base that already has /AF, /Names or /PageMode does not get duplicate keys.
  # Shapes we cannot safely merge in-place are refused rather than corrupted.
  defp catalog_obj(num, catalog_dict, fs_num, filename) do
    inner = binary_part(catalog_dict, 0, byte_size(catalog_dict) - 2)

    with {:ok, inner} <- merge_af(inner, fs_num),
         {:ok, inner} <- merge_names(inner, fs_num, filename) do
      inner = maybe_page_mode(inner)
      {:ok, "#{num} 0 obj\n" <> inner <> ">>\nendobj\n"}
    end
  end

  defp merge_af(inner, fs_num) do
    cond do
      Regex.match?(~r/\/AF\s*\[/, inner) ->
        {:ok, Regex.replace(~r/\/AF\s*\[/, inner, "/AF [#{fs_num} 0 R ", global: false)}

      Regex.match?(~r/\/AF\s+\d+\s+\d+\s+R/, inner) ->
        {:error, :af_indirect_unsupported}

      true ->
        {:ok, inner <> " /AF [#{fs_num} 0 R]"}
    end
  end

  defp merge_names(inner, fs_num, filename) do
    entry = "/EmbeddedFiles << /Names [(#{pdf_string(filename)}) #{fs_num} 0 R] >>"

    cond do
      Regex.match?(~r/\/Names\s+\d+\s+\d+\s+R/, inner) ->
        {:error, :names_indirect_unsupported}

      String.contains?(inner, "/EmbeddedFiles") ->
        # Base already has embedded files; merging into an existing name tree is
        # out of v1 scope (re-embedding into a Factur-X).
        {:error, :already_has_embedded_files}

      Regex.match?(~r/\/Names\s*<</, inner) ->
        {:ok, Regex.replace(~r/\/Names\s*<</, inner, "/Names << #{entry} ", global: false)}

      true ->
        {:ok, inner <> " /Names << #{entry} >>"}
    end
  end

  defp maybe_page_mode(inner) do
    if String.contains?(inner, "/PageMode"),
      do: inner,
      else: inner <> " /PageMode /UseAttachments"
  end

  defp embedded_file_obj(num, data, orig_size, moddate) do
    "#{num} 0 obj\n" <>
      "<< /Type /EmbeddedFile /Subtype /text#2Fxml /Filter /FlateDecode" <>
      " /Length #{byte_size(data)} /Params << /ModDate (#{moddate}) /Size #{orig_size} >> >>\n" <>
      "stream\n" <> data <> "\nendstream\nendobj\n"
  end

  defp filespec_obj(num, emb_num, filename) do
    name = pdf_string(filename)

    "#{num} 0 obj\n" <>
      "<< /Type /Filespec /F (#{name}) /UF (#{name}) /AFRelationship /Data" <>
      " /Desc (Factur-X XML file) /EF << /F #{emb_num} 0 R /UF #{emb_num} 0 R >> >>\nendobj\n"
  end

  # --- tiny PDF helpers (classic xref) -------------------------------------

  defp trailer_dict(pdf) do
    case last_match(pdf, "trailer") do
      nil -> {:error, :no_trailer}
      pos -> {:ok, balanced_dict(pdf, pos)}
    end
  end

  # The last object N definition, returned as its outer << ... >> dictionary.
  defp object_dict(pdf, num) do
    case last_object_pos(pdf, num) do
      nil -> {:error, {:missing_object, num}}
      pos -> {:ok, balanced_dict(pdf, pos)}
    end
  end

  # The stream bytes of object N (used for the XMP), inflated if FlateDecode —
  # many PDF/A producers compress the /Metadata stream.
  defp object_stream(pdf, num) do
    with pos when is_integer(pos) <- last_object_pos(pdf, num),
         dict = balanced_dict(pdf, pos),
         {s, _} <- :binary.match(pdf, "stream", scope: {pos, byte_size(pdf) - pos}),
         data_start = skip_eol(pdf, s + 6),
         {e, _} <-
           :binary.match(pdf, "endstream", scope: {data_start, byte_size(pdf) - data_start}) do
      raw = stream_data(pdf, dict, data_start, e)
      if String.contains?(dict, "/FlateDecode"), do: inflate(raw), else: {:ok, raw}
    else
      _ -> {:error, {:no_stream, num}}
    end
  end

  # Prefer `/Length`, which is where the stream actually stops. Guessing instead
  # at the EOL that precedes `endstream` eats a real byte as soon as the data
  # itself ends with CR or LF — for a deflated `/Metadata` that is roughly one
  # base in 256, and the embedding then fails outright on `:inflate_failed`.
  #
  # A `/Length` is only taken once it lands on `endstream` with nothing but an
  # EOL in between: producers do get it wrong, and a wrong length would silently
  # truncate where the scan would have worked.
  defp stream_data(pdf, dict, data_start, e) do
    # The `\b` matters: without it the engine backtracks into the digits when
    # the lookahead fires, so `/Length 120 0 R` captures "12" instead of failing.
    with [_, n] <- Regex.run(~r{/Length\s+(\d+)\b(?!\s*\d+\s+R)}, dict),
         len = String.to_integer(n),
         true <- len <= e - data_start,
         true <-
           binary_part(pdf, data_start + len, e - data_start - len) in ["", "\n", "\r\n", "\r"] do
      binary_part(pdf, data_start, len)
    else
      _ -> binary_part(pdf, data_start, strip_eol(pdf, data_start, e) - data_start)
    end
  end

  defp inflate(data) do
    {:ok, :zlib.uncompress(data)}
  rescue
    _ -> {:error, :inflate_failed}
  catch
    _, _ -> {:error, :inflate_failed}
  end

  defp last_object_pos(pdf, num) do
    ~r/(?<!\d)#{num}\s+\d+\s+obj\b/
    |> Regex.scan(pdf, return: :index)
    |> List.last()
    |> case do
      [{s, _} | _] -> s
      _ -> nil
    end
  end

  defp last_match(pdf, needle) do
    :binary.matches(pdf, needle)
    |> List.last()
    |> case do
      {s, _} -> s
      _ -> nil
    end
  end

  # From `pos`, find the first `<<` and return the balanced `<< ... >>` substring.
  defp balanced_dict(pdf, pos) do
    {open, _} = :binary.match(pdf, "<<", scope: {pos, byte_size(pdf) - pos})
    tokens = delim_tokens(pdf, open)
    close_end = match_close(tokens, 0, nil)
    binary_part(pdf, open, close_end - open)
  end

  defp delim_tokens(pdf, from) do
    scope = {from, byte_size(pdf) - from}

    (Enum.map(:binary.matches(pdf, "<<", scope: scope), fn {p, _} -> {p, :open} end) ++
       Enum.map(:binary.matches(pdf, ">>", scope: scope), fn {p, _} -> {p, :close} end))
    |> Enum.sort()
  end

  defp match_close([{p, :open} | rest], depth, _), do: match_close(rest, depth + 1, p)
  defp match_close([{p, :close} | _], 1, _), do: p + 2
  defp match_close([{_, :close} | rest], depth, first), do: match_close(rest, depth - 1, first)
  defp match_close([], _, _), do: raise("unbalanced dictionary")

  defp prev_startxref(pdf) do
    case Regex.scan(~r/startxref\s+(\d+)/, pdf) |> List.last() do
      [_, n] -> {:ok, String.to_integer(n)}
      _ -> {:error, :no_startxref}
    end
  end

  defp skip_eol(bin, pos) do
    case bin do
      <<_::binary-size(pos), "\r\n", _::binary>> -> pos + 2
      <<_::binary-size(pos), "\n", _::binary>> -> pos + 1
      <<_::binary-size(pos), "\r", _::binary>> -> pos + 1
      _ -> pos
    end
  end

  defp strip_eol(bin, start, e) when e - 2 >= start do
    case binary_part(bin, e - 2, 2) do
      "\r\n" -> e - 2
      <<_, c>> when c in [?\r, ?\n] -> e - 1
      _ -> e
    end
  end

  defp strip_eol(_bin, _start, e), do: e

  # --- misc -----------------------------------------------------------------

  defp capture(bin, re) do
    case Regex.run(re, bin) do
      [_, v] -> v
      _ -> nil
    end
  end

  defp capture_int(bin, re) do
    case capture(bin, re) do
      nil -> {:error, {:not_found, re}}
      v -> {:ok, String.to_integer(v)}
    end
  end

  # Escape a filename for a PDF literal string: \ ( ) must be escaped (backslash
  # first, so we don't double-escape the ones we add).
  defp pdf_string(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("(", "\\(")
    |> String.replace(")", "\\)")
  end

  defp pdf_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "D:%Y%m%d%H%M%S+00'00'")
  end
end
