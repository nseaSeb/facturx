defmodule Facturx.TestPDF do
  @moduledoc """
  Synthetic PDF/A bases, assembled in the test process.

  `Facturx.Embed` and `Facturx.Extract` were only ever exercised against the
  private fixtures under `test/fixtures/local/`, which are not committed — so CI
  ran none of that code. These builders give both modules a base to work on
  anywhere, with byte-exact cross-reference offsets so the result can be checked
  structurally and not merely round-tripped.

  This is **not** a PDF/A producer and a passing test here says nothing about
  conformance: what follows is only the minimum `Facturx.Embed` reads — a
  catalog, an XMP `/Metadata` stream and a one-page tree — with no font, no
  OutputIntent and no ICC profile. veraPDF over real producer output, in the
  `:local` tests, remains the only conformance oracle.
  """

  @header <<"%PDF-1.7\n%", 0xE2, 0xE3, 0xCF, 0xD3, "\n">>
  @doc_id "<0123456789ABCDEF0123456789ABCDEF>"

  @doc """
  A PDF/A base with a classic cross-reference table.

  Objects 1 to 6 are the catalog, the XMP metadata stream, the page tree, the
  page, its content stream and the info dictionary; any `:extra_objects` must
  therefore number from 7 up.

  Options:

    * `:part` — the `pdfaid:part` value in the XMP: `2` (default), `1` or `3`.
      `nil` leaves the PDF/A identification out altogether, giving a plain PDF.
    * `:compress_xmp` — deflate the `/Metadata` stream, as most producers do
      (default `false`).
    * `:catalog_extra` — raw text spliced into the catalog dictionary, to reach
      the merge branches of `Embed` (a pre-existing `/Names`, `/AF`,
      `/PageMode`).
    * `:extra_objects` — `[{number, body}]`, appended after the standard six.
    * `:title` — the `dc:title` of the XMP packet. Only lever on the length of
      the metadata stream, which is what decides its last compressed byte.
  """
  def base(opts \\ []) do
    objects = objects(opts)
    size = size(objects)
    {body, offsets} = write_objects(objects)
    xref_offset = byte_size(body)

    body <> xref_table(offsets, size) <> trailer(size, xref_offset)
  end

  @doc """
  A base whose cross-reference is an xref *stream* rather than a table, and
  which consequently has no `trailer` keyword.

  This is the PDF 1.5+ shape both modules decline to touch (ADR 0001); it exists
  here to pin that refusal, not to be embedded into.
  """
  def xref_stream_base(opts \\ []) do
    objects = objects(opts)
    {body, offsets} = write_objects(objects)

    xref_num = size(objects)
    xref_offset = byte_size(body)
    offsets = Map.put(offsets, xref_num, xref_offset)
    size = xref_num + 1

    data =
      for n <- 0..(size - 1), into: <<>> do
        case Map.fetch(offsets, n) do
          {:ok, offset} -> <<1, offset::32, 0::16>>
          :error -> <<0, 0::32, 65_535::16>>
        end
      end

    dict =
      "<< /Type /XRef /Size #{size} /W [1 4 2] /Root 1 0 R /Info 6 0 R" <>
        " /Length #{byte_size(data)} >>"

    body <>
      "#{xref_num} 0 obj\n" <>
      dict <>
      "\nstream\n" <>
      data <>
      "\nendstream\nendobj\n" <>
      "startxref\n#{xref_offset}\n%%EOF\n"
  end

  @doc """
  The entries of the **last** cross-reference section of `pdf`, as
  `%{object_number => byte_offset}`. Free entries are dropped.

  On the output of `Facturx.generate/3` that is the incremental section, which
  covers exactly the objects the update changed or added.
  """
  def last_xref(pdf) do
    {s, _} = pdf |> :binary.matches("\nxref\n") |> List.last()
    {e, _} = :binary.match(pdf, "trailer", scope: {s, byte_size(pdf) - s})

    pdf
    |> binary_part(s + 6, e - s - 6)
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> parse_subsections(%{})
  end

  @doc """
  The raw bytes of the `/Metadata` stream (object 2) of `pdf`, still deflated if
  the base was built that way.

  Used to search for a base whose compressed metadata ends on a given byte —
  `Embed` has to read that stream before it can promote the XMP.
  """
  def metadata_stream(pdf) do
    # The lookbehind, as in Embed.last_object_pos/2: a bare match would also hit
    # inside `12 0 obj`, and an :extra_objects number in the twenties or thirties
    # would silently send this at the wrong object's stream.
    [{s, _} | _] = Regex.run(~r/(?<!\d)2 0 obj/, pdf, return: :index) |> Enum.take(1)
    {open, _} = :binary.match(pdf, "stream\n", scope: {s, byte_size(pdf) - s})
    start = open + byte_size("stream\n")
    {close, _} = :binary.match(pdf, "\nendstream", scope: {start, byte_size(pdf) - start})

    binary_part(pdf, start, close - start)
  end

  # --- objects --------------------------------------------------------------

  defp objects(opts) do
    part = Keyword.get(opts, :part, 2)
    catalog_extra = Keyword.get(opts, :catalog_extra, "")
    extra_objects = Keyword.get(opts, :extra_objects, [])

    xmp = xmp(part, Keyword.get(opts, :title, "facturx synthetic base"))

    {xmp_bytes, filter} =
      if Keyword.get(opts, :compress_xmp, false),
        do: {:zlib.compress(xmp), " /Filter /FlateDecode"},
        else: {xmp, ""}

    content = "q Q\n"

    [
      {1, "<< /Type /Catalog /Pages 3 0 R /Metadata 2 0 R#{pad(catalog_extra)} >>"},
      {2,
       stream(
         "<< /Type /Metadata /Subtype /XML#{filter} /Length #{byte_size(xmp_bytes)} >>",
         xmp_bytes
       )},
      {3, "<< /Type /Pages /Kids [4 0 R] /Count 1 >>"},
      {4,
       "<< /Type /Page /Parent 3 0 R /MediaBox [0 0 595 842] /Resources << >>" <>
         " /Contents 5 0 R >>"},
      {5, stream("<< /Length #{byte_size(content)} >>", content)},
      {6, "<< /Producer (facturx test builder) >>"}
    ] ++ extra_objects
  end

  defp size(objects), do: (objects |> Enum.map(&elem(&1, 0)) |> Enum.max()) + 1

  defp pad(""), do: ""
  defp pad(extra), do: " " <> extra

  defp stream(dict, data), do: dict <> "\nstream\n" <> data <> "\nendstream"

  # The XMP packet. Deliberately free of any `>>` sequence: `Embed` closes an
  # object dictionary on the first one it meets, wherever it sits.
  defp xmp(part, title) do
    identification =
      if part do
        ~s(<rdf:Description rdf:about="" xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/">) <>
          "<pdfaid:part>#{part}</pdfaid:part><pdfaid:conformance>B</pdfaid:conformance>" <>
          "</rdf:Description>"
      else
        ""
      end

    ~s(<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>) <>
      ~s(<x:xmpmeta xmlns:x="adobe:ns:meta/">) <>
      ~s(<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">) <>
      identification <>
      ~s(<rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">) <>
      ~s(<dc:title><rdf:Alt><rdf:li xml:lang="x-default">) <>
      title <>
      "</rdf:li></rdf:Alt></dc:title></rdf:Description>" <>
      "</rdf:RDF></x:xmpmeta>" <>
      ~s(<?xpacket end="w"?>)
  end

  # --- assembly -------------------------------------------------------------

  # Records, for each object, the offset of the first byte of its `N 0 obj`
  # header — which is what an xref entry must point at.
  defp write_objects(objects) do
    Enum.reduce(objects, {@header, %{}}, fn {num, body}, {acc, offsets} ->
      {acc <> "#{num} 0 obj\n" <> body <> "\nendobj\n", Map.put(offsets, num, byte_size(acc))}
    end)
  end

  defp xref_table(offsets, size) do
    entries =
      Enum.map_join(0..(size - 1), "", fn n ->
        case Map.fetch(offsets, n) do
          {:ok, offset} ->
            String.pad_leading(Integer.to_string(offset), 10, "0") <> " 00000 n\r\n"

          :error ->
            "0000000000 65535 f\r\n"
        end
      end)

    "xref\n0 #{size}\n" <> entries
  end

  defp trailer(size, xref_offset) do
    "trailer\n<< /Size #{size} /Root 1 0 R /Info 6 0 R" <>
      " /ID [#{@doc_id} #{@doc_id}] >>\nstartxref\n#{xref_offset}\n%%EOF\n"
  end

  # --- xref parsing ---------------------------------------------------------

  defp parse_subsections([], acc), do: acc

  defp parse_subsections([header | rest], acc) do
    [start, count] = header |> String.split() |> Enum.map(&String.to_integer/1)
    {entries, rest} = Enum.split(rest, count)

    acc =
      entries
      |> Enum.with_index(start)
      |> Enum.reduce(acc, fn {entry, num}, acc ->
        case String.split(entry) do
          [offset, _gen, "n"] -> Map.put(acc, num, String.to_integer(offset))
          _ -> acc
        end
      end)

    parse_subsections(rest, acc)
  end
end
