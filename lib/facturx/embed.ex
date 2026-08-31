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

  Writes the cross-reference back in the form the base uses — a classic table and
  trailer, or a PDF 1.5+ cross-reference stream — and never mixes the two: a
  table appended to a stream-based document is what a strict reader is entitled
  to reject. A catalog compressed inside an object stream is read from there and
  rewritten at top level, which is what an incremental update means.
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

    with :ok <- ensure_not_encrypted(pdf),
         {:ok, shape} <- xref_shape(pdf),
         {:ok, ctx} <- parse_base(pdf, shape),
         :ok <- check_pdfa_level(ctx.part) do
      build(pdf, xml, ctx, profile, filename)
    end
  rescue
    # The input is a caller-supplied binary, so every malformed shape it can
    # take is an input error and owed an `{:error, _}` — the contract this spec
    # states. The known ones are refused by name above; this catches the rest.
    #
    # Deliberately narrow, and the same list `Facturx.Extract` uses: these three
    # are what slicing and matching on a malformed binary raise. A
    # `FunctionClauseError` from a future defect in the writer is a bug here, not
    # a fault in the caller's file, and must not be served as one — a blanket
    # rescue would also let the "never raises" property pass over it.
    e in [ArgumentError, MatchError, ErlangError] -> {:error, e}
  end

  # --- input validation -----------------------------------------------------

  # Nothing here can read an encrypted file, and nothing used to notice: the
  # outcome was a failed inflate or bytes that meant nothing. Decrypt upstream.
  defp ensure_not_encrypted(pdf) do
    if Facturx.PDF.encrypted?(pdf), do: {:error, :encrypted_pdf_unsupported}, else: :ok
  end

  # Which of the two cross-reference forms the base uses. Both are written back
  # in kind: an incremental update must not change the shape of what it appends
  # to, and a hybrid file — a table added to a stream-based document — is exactly
  # the thing a strict PDF/A reader is entitled to reject.
  defp xref_shape(pdf) do
    cond do
      String.contains?(pdf, "\ntrailer") -> {:ok, :table}
      Regex.match?(~r|/Type\s*/XRef|, pdf) -> {:ok, :stream}
      true -> {:error, :no_trailer}
    end
  end

  defp check_pdfa_level(3), do: :ok
  defp check_pdfa_level(2), do: :ok
  defp check_pdfa_level(1), do: {:error, {:unsupported_pdfa, "PDF/A-1"}}
  defp check_pdfa_level(nil), do: {:error, :not_pdfa}
  defp check_pdfa_level(other), do: {:error, {:unsupported_pdfa, other}}

  # --- parse what we need from the base ------------------------------------

  defp parse_base(pdf, shape) do
    index = Facturx.PDF.object_index(pdf)

    with {:ok, prev} <- prev_startxref(pdf),
         {:ok, trailer} <- trailer_dict(pdf, shape, prev),
         {:ok, root_num} <- capture_int(trailer, ~r/\/Root\s+(\d+)\s+\d+\s+R/),
         {:ok, size} <- capture_int(trailer, ~r/\/Size\s+(\d+)/),
         {:ok, catalog} <- object_dict(index, root_num),
         {:ok, meta_num} <- capture_int(catalog, ~r/\/Metadata\s+(\d+)\s+\d+\s+R/),
         {:ok, xmp} <- object_stream(pdf, meta_num) do
      {:ok,
       %{
         shape: shape,
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
    # A cross-reference stream is itself an object, and needs a number of its own.
    new_size = if ctx.shape == :stream, do: ctx.size + 3, else: ctx.size + 2

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

  # Append each object, tracking byte offsets, then the cross-reference in the
  # form the base uses — a classic section and trailer, or a stream object.
  defp assemble(prefix, objects, new_size, ctx) do
    {body, offsets} =
      Enum.reduce(objects, {prefix, %{}}, fn {num, bytes}, {acc, offs} ->
        {acc <> bytes, Map.put(offs, num, byte_size(acc))}
      end)

    nums = objects |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    xref_offset = byte_size(body)

    case ctx.shape do
      :table ->
        trailer =
          "trailer\n<< /Size #{new_size} /Root #{ctx.root_num} 0 R" <>
            info_entry(ctx.info) <>
            id_entry(ctx.id) <>
            " /Prev #{ctx.prev} >>\nstartxref\n#{xref_offset}\n%%EOF\n"

        body <> xref_subsections(nums, offsets) <> trailer

      :stream ->
        # The stream object is the last number, and its own entry has to be in
        # the table it is: a reader that cannot find the cross-reference stream
        # cannot find anything.
        self_num = new_size - 1
        offsets = Map.put(offsets, self_num, xref_offset)

        body <>
          xref_stream_obj(self_num, Enum.sort([self_num | nums]), offsets, new_size, ctx) <>
          "startxref\n#{xref_offset}\n%%EOF\n"
    end
  end

  # A cross-reference stream (PDF 32000-1, 7.5.8). `/W [1 4 2]` is one byte of
  # entry type, four of offset, two of generation — the widths the writers in the
  # wild use, and wide enough for any file this library will append to.
  #
  # No `/DecodeParms`: a predictor only pays on a full table of thousands of
  # entries, and this one holds four.
  defp xref_stream_obj(num, nums, offsets, new_size, ctx) do
    entries =
      for n <- nums, into: <<>> do
        <<1, Map.fetch!(offsets, n)::32, 0::16>>
      end

    data = :zlib.compress(entries)

    dict =
      "<< /Type /XRef /Size #{new_size} /W [1 4 2] /Index [#{index_array(nums)}]" <>
        " /Root #{ctx.root_num} 0 R" <>
        info_entry(ctx.info) <>
        id_entry(ctx.id) <>
        " /Prev #{ctx.prev} /Filter /FlateDecode /Length #{byte_size(data)} >>"

    "#{num} 0 obj\n" <> dict <> "\nstream\n" <> data <> "\nendstream\nendobj\n"
  end

  # `/Index` is the same contiguous runs a classic section splits into, flattened
  # to `first count first count`.
  defp index_array(nums) do
    nums
    |> contiguous_runs()
    |> Enum.map_join(" ", fn run -> "#{hd(run)} #{length(run)}" end)
  end

  # Group the changed object numbers into contiguous xref subsections.
  defp xref_subsections(nums, offsets) do
    runs = contiguous_runs(nums)

    entries =
      Enum.map_join(runs, "", fn run ->
        "#{hd(run)} #{length(run)}\n" <>
          Enum.map_join(run, "", fn n -> xref_entry(Map.fetch!(offsets, n)) end)
      end)

    "xref\n" <> entries
  end

  defp contiguous_runs(nums) do
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

  # The document's trailer, whichever form it takes. With a cross-reference
  # stream there is no `trailer` keyword: its dictionary carries the same keys —
  # /Root, /Size, /Info, /ID, /Prev — and `startxref` points straight at it.
  defp trailer_dict(pdf, :table, _prev) do
    case last_match(pdf, "trailer") do
      nil -> {:error, :no_trailer}
      pos -> Facturx.PDF.balanced_dict(pdf, pos)
    end
  end

  defp trailer_dict(pdf, :stream, prev) when prev < byte_size(pdf) do
    Facturx.PDF.balanced_dict(pdf, prev)
  end

  defp trailer_dict(_pdf, :stream, _prev), do: {:error, :no_trailer}

  # Object N's outer << ... >> dictionary, from the shared index — which reaches
  # inside object streams. The catalog of a PDF 1.5 file is usually compressed in
  # one, so looking for `N 0 obj` in the raw bytes would not find it.
  defp object_dict(index, num) do
    case Map.get(index, {num, 0}) do
      {body, _} -> Facturx.PDF.balanced_dict(body, 0)
      nil -> {:error, {:missing_object, num}}
    end
  end

  # The stream bytes of object N (used for the XMP), inflated if FlateDecode —
  # many PDF/A producers compress the /Metadata stream.
  defp object_stream(pdf, num) do
    with pos when is_integer(pos) <- last_object_pos(pdf, num),
         {:ok, dict} <- Facturx.PDF.balanced_dict(pdf, pos),
         {s, _} <- :binary.match(pdf, "stream", scope: {pos, byte_size(pdf) - pos}),
         data_start = Facturx.PDF.skip_eol(pdf, s + 6),
         {:ok, raw} <- stream_data(pdf, dict, data_start) do
      if String.contains?(dict, "/FlateDecode"), do: inflate(raw), else: {:ok, raw}
    else
      _ -> {:error, {:no_stream, num}}
    end
  end

  defp stream_data(pdf, dict, data_start) do
    case Facturx.PDF.stream_length(dict, pdf, data_start) do
      {:ok, len} -> {:ok, binary_part(pdf, data_start, len)}
      :error -> scan_to_endstream(pdf, data_start)
    end
  end

  # No usable `/Length`. Unlike `Facturx.Extract`, which holds one object's
  # bytes and can take the last `endstream` in them, here the scope is the whole
  # file — so the first one after the data is the only defensible guess.
  defp scan_to_endstream(pdf, data_start) do
    case :binary.match(pdf, "endstream", scope: {data_start, byte_size(pdf) - data_start}) do
      {e, _} ->
        {:ok,
         binary_part(
           pdf,
           data_start,
           Facturx.PDF.strip_trailing_eol(pdf, data_start, e) - data_start
         )}

      :nomatch ->
        :error
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

  defp prev_startxref(pdf) do
    case Regex.scan(~r/startxref\s+(\d+)/, pdf) |> List.last() do
      [_, n] -> {:ok, String.to_integer(n)}
      _ -> {:error, :no_startxref}
    end
  end

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
