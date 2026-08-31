defmodule Facturx.PdfRoundtripTest do
  @moduledoc """
  Embed / Extract over a synthetic PDF/A base (`Facturx.TestPDF`).

  Everything here runs everywhere, CI included — that is the point. The `:local`
  tests remain the conformance oracle (real producer output, veraPDF); these
  cover the structure, which nothing else did.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Facturx.TestPDF

  @xml ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
         ~s(<rsm:CrossIndustryInvoice xmlns:rsm="urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100" xmlns:ram="urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:100">) <>
         "<rsm:ExchangedDocumentContext><ram:GuidelineSpecifiedDocumentContextParameter>" <>
         "<ram:ID>urn:cen.eu:en16931:2017</ram:ID>" <>
         "</ram:GuidelineSpecifiedDocumentContextParameter></rsm:ExchangedDocumentContext>" <>
         "</rsm:CrossIndustryInvoice>"

  describe "generate/3 then extract/1" do
    test "the embedded XML comes back byte-identical, with its name and profile" do
      base = TestPDF.base()

      assert {:ok, out} = Facturx.generate(base, @xml, profile: :en16931)
      assert byte_size(out) > byte_size(base)
      # Incremental update: the base is preserved verbatim as the prefix.
      assert :binary.part(out, 0, byte_size(base)) == base

      assert {:ok, %{xml: xml, filename: "factur-x.xml", profile: :en16931}} =
               Facturx.extract(out)

      assert xml == @xml
    end

    test "the XMP is promoted to PDF/A-3 and carries the Factur-X schema" do
      {:ok, out} = Facturx.generate(TestPDF.base(part: 2), @xml, profile: :basic)

      assert out =~ "<pdfaid:part>3</pdfaid:part>"
      assert out =~ "urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0#"
      assert out =~ "<fx:DocumentType>INVOICE</fx:DocumentType>"
      assert out =~ "<fx:ConformanceLevel>BASIC</fx:ConformanceLevel>"
      assert out =~ "/AFRelationship /Data"
      assert out =~ "/PageMode /UseAttachments"
    end

    test "an already-A-3 base keeps its part, and a deflated /Metadata is handled" do
      {:ok, out} = Facturx.generate(TestPDF.base(part: 3, compress_xmp: true), @xml)

      assert out =~ "<pdfaid:part>3</pdfaid:part>"
      refute out =~ "<pdfaid:part>2</pdfaid:part>"
      assert {:ok, %{xml: @xml}} = Facturx.extract(out)
    end

    test "a filename with parentheses survives the PDF literal-string escaping" do
      name = "fac(tur)-x.xml"
      {:ok, out} = Facturx.generate(TestPDF.base(), @xml, filename: name)

      assert out =~ "/UF (fac\\(tur\\)-x.xml)"
      assert {:ok, %{filename: ^name, xml: @xml}} = Facturx.extract(out)
    end

    test "nothing returned retains the PDF binary" do
      # Long enough to be a refc binary if it were sliced out of the PDF: below
      # 64 bytes the runtime copies to the heap anyway and the check is blind.
      name = String.duplicate("n", 80) <> ".xml"
      {:ok, out} = Facturx.generate(TestPDF.base(), @xml, filename: name)
      {:ok, %{xml: xml, filename: filename}} = Facturx.extract(out)

      # A sub-binary would report the whole PDF as referenced and keep those
      # bytes alive for as long as the result is held. Both values happen to be
      # built fresh today (inflate, unescape), so this guards the moduledoc's
      # promise against a future version that returns a slice — it does not
      # prove the current `:binary.copy/1` calls are what makes it hold.
      assert :binary.referenced_byte_size(xml) == byte_size(xml)
      assert :binary.referenced_byte_size(filename) == byte_size(filename)
    end
  end

  describe "streams whose data ends on an EOL byte" do
    # `/Length` says where a stream stops. Guessing at the EOL that precedes
    # `endstream` cuts a real byte as soon as the data itself ends with CR or
    # LF — for deflate that byte is the low byte of the adler32, so it happens
    # about once in 256 documents, and the stream then no longer inflates.
    test "an XML whose deflate stream ends with CR still round-trips" do
      xml = xml_deflating_to(0x0D)

      {:ok, out} = Facturx.generate(TestPDF.base(), xml)
      assert {:ok, %{xml: ^xml}} = Facturx.extract(out)
    end

    test "a base whose deflated /Metadata ends with CR is still embeddable" do
      base = base_with_metadata_ending_on(0x0D)

      assert {:ok, out} = Facturx.generate(base, @xml)
      assert out =~ "<pdfaid:part>3</pdfaid:part>"
      assert {:ok, %{xml: @xml}} = Facturx.extract(out)
    end
  end

  describe "stream length, over arbitrary payloads" do
    # The two tests above pin the CR and LF cases with a payload chosen for it.
    # This covers the same code from the other side: whatever the deflate stream
    # happens to end on, and whatever the payload contains — `endstream` and
    # `endobj` included, which compression hides but a naive scan would not —
    # what comes out is what went in.
    defp payload do
      gen all(body <- string(:printable, max_length: 300)) do
        ~s(<?xml version="1.0" encoding="UTF-8"?><doc>) <> body <> "</doc>"
      end
    end

    property "any payload comes back byte-identical" do
      base = TestPDF.base()

      # More runs than the default 100: the failing tail byte occurs about once
      # in 256 draws, so 100 would miss it more often than not.
      check all(xml <- payload(), max_runs: 400) do
        assert {:ok, out} = Facturx.generate(base, xml)
        assert {:ok, %{xml: ^xml}} = Facturx.extract(out)
      end
    end

    property "a payload containing PDF keywords is not cut short by them" do
      base = TestPDF.base()

      check all(
              body <- string(:printable, max_length: 80),
              keyword <- member_of(["endstream", "endobj", "stream", ">>", "%%EOF"])
            ) do
        xml = ~s(<?xml version="1.0" encoding="UTF-8"?><doc>) <> body <> keyword <> "</doc>"

        assert {:ok, out} = Facturx.generate(base, xml)
        assert {:ok, %{xml: ^xml}} = Facturx.extract(out)
      end
    end
  end

  describe "streams whose data contains PDF keywords" do
    # `endstream` cannot be found by scanning: stream data contains those bytes.
    # Deflate emits stored blocks that copy their input verbatim, and an
    # uncompressed XMP packet can simply mention the word. Both cases used to
    # cut the stream short — silently, since a shorter slice still parses.
    test "an embedded payload whose deflate stream contains \"endstream\" round-trips" do
      xml = xml_deflating_with("endstream")

      {:ok, out} = Facturx.generate(TestPDF.base(), xml)
      assert {:ok, %{xml: ^xml}} = Facturx.extract(out)
    end

    test "a base whose uncompressed /Metadata contains \"endstream\" keeps its XMP whole" do
      base = TestPDF.base(title: "Rapport endstream 2026")

      assert {:ok, out} = Facturx.generate(base, @xml)
      # The promotion read the whole packet, not the slice before the keyword.
      assert out =~ "<pdfaid:part>3</pdfaid:part>"
      assert out =~ "Rapport endstream 2026"
      assert out =~ "urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0#"
    end
  end

  describe "cross-reference integrity" do
    # The round-trip above proves nothing about the xref: Embed reads the base
    # by scanning for `N G obj`, never through the table. A wrong offset would
    # produce a broken PDF that still round-trips here — hence this test.
    test "every entry of the appended section points at its object header" do
      base = TestPDF.base()
      {:ok, out} = Facturx.generate(base, @xml)

      table = TestPDF.last_xref(out)
      # The overridden metadata and catalog, plus the embedded file and its
      # filespec: objects 1, 2, 7 and 8 (the base's /Size being 7).
      assert map_size(table) == 4

      for {num, offset} <- table do
        assert :binary.part(out, offset, byte_size("#{num} 0 obj")) == "#{num} 0 obj",
               "xref entry #{num} points at offset #{offset}, which is not its header"
      end
    end

    test "the synthetic base's own table is exact" do
      base = TestPDF.base()
      table = TestPDF.last_xref(base)

      assert map_size(table) == 6

      for {num, offset} <- table do
        assert :binary.part(base, offset, byte_size("#{num} 0 obj")) == "#{num} 0 obj"
      end
    end

    test "the appended trailer chains back to the base's own table" do
      base = TestPDF.base()
      {:ok, out} = Facturx.generate(base, @xml)

      # A wrong /Prev leaves every object of the base unreachable to a
      # conforming reader, and no other test here would notice: Extract scans
      # for `N G obj` and never reads a table.
      [_, prev] = Regex.run(~r|/Prev\s+(\d+)|, out)
      [_, base_startxref] = Regex.scan(~r/startxref\s+(\d+)/, base) |> List.last()

      assert prev == base_startxref
      assert :binary.part(out, String.to_integer(prev), 4) == "xref"
    end

    test "startxref points at the appended section" do
      {:ok, out} = Facturx.generate(TestPDF.base(), @xml)

      [_, offset] = Regex.scan(~r/startxref\s+(\d+)/, out) |> List.last()
      assert :binary.part(out, String.to_integer(offset), 4) == "xref"
    end
  end

  # PDF 1.5+ keeps its cross-reference in a stream and most of its dictionaries
  # inside object streams. Both were refused outright until now, which ruled out
  # the output of most current producers.
  describe "cross-reference streams and object streams" do
    for {label, builder} <- [
          {"a cross-reference stream base", :xref_stream_base},
          {"an object-stream base", :objstm_base}
        ] do
      test "#{label} round-trips" do
        base = apply(TestPDF, unquote(builder), [])

        refute base =~ "\ntrailer"

        assert {:ok, out} = Facturx.generate(base, @xml, profile: :en16931)
        # Still an incremental update: the base survives byte for byte.
        assert :binary.part(out, 0, byte_size(base)) == base

        assert {:ok, %{xml: @xml, filename: "factur-x.xml", profile: :en16931}} =
                 Facturx.extract(out)
      end

      test "#{label} gets a cross-reference stream back, never a hybrid" do
        base = apply(TestPDF, unquote(builder), [])
        {:ok, out} = Facturx.generate(base, @xml)

        # A classic table appended to a stream-based document is what a strict
        # PDF/A reader is entitled to reject.
        refute out =~ "\ntrailer"
        assert out =~ "/Type /XRef"
      end

      test "#{label} keeps its XMP promotion" do
        base = apply(TestPDF, unquote(builder), [])
        {:ok, out} = Facturx.generate(base, @xml, profile: :basic)

        assert out =~ "<pdfaid:part>3</pdfaid:part>"
        assert out =~ "<fx:ConformanceLevel>BASIC</fx:ConformanceLevel>"
        assert out =~ "urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0#"
      end
    end

    test "the catalog is found even when it is compressed inside an object stream" do
      base = TestPDF.objstm_base()

      # The point of the shape: `1 0 obj` is nowhere in the raw bytes.
      refute Regex.match?(~r/(?<!\d)1 0 obj/, base)

      {:ok, out} = Facturx.generate(base, @xml)
      # The update rewrites object 1, so the merged catalog is top level.
      assert out =~ "/AFRelationship /Data"
      assert out =~ "/PageMode /UseAttachments"
    end

    test "every offset the written cross-reference stream states is an object header" do
      base = TestPDF.xref_stream_base()
      {:ok, out} = Facturx.generate(base, @xml)

      for {number, offset} <- last_xref_stream(out) do
        assert binary_part(out, offset, byte_size("#{number} 0 obj")) == "#{number} 0 obj",
               "object #{number}: offset #{offset} does not land on its header"
      end
    end

    test "an object stream whose contents cannot be inflated is not fatal" do
      base = TestPDF.objstm_base()
      {s, _} = :binary.match(base, "/ObjStm")
      # Corrupt the compressed payload of the container, not its dictionary.
      broken =
        binary_part(base, 0, s + 40) <>
          "@@@@" <> binary_part(base, s + 44, byte_size(base) - s - 44)

      assert {:error, _} = Facturx.generate(broken, @xml)
      assert {:error, _} = Facturx.extract(broken)
    end
  end

  describe "catalog merge" do
    test "merges into a base that already has a /Names dict, keeping /Dests" do
      base =
        TestPDF.base(
          catalog_extra: "/Names << /Dests 7 0 R >>",
          extra_objects: [{7, "<< /Names [] >>"}]
        )

      assert {:ok, out} = Facturx.generate(base, @xml)
      assert {:ok, %{xml: @xml}} = Facturx.extract(out)

      catalog = last_catalog(out)
      assert catalog =~ "/Dests 7 0 R"
      assert catalog =~ "/EmbeddedFiles"
      # One /Names key, not two: a duplicate would make the catalog ambiguous.
      assert length(Regex.scan(~r|/Names\s*<<|, catalog)) == 1
    end

    test "prepends to an existing /AF array rather than replacing it" do
      base =
        TestPDF.base(catalog_extra: "/AF [7 0 R]", extra_objects: [{7, "<< /Type /Filespec >>"}])

      assert {:ok, out} = Facturx.generate(base, @xml)
      catalog = last_catalog(out)

      assert catalog =~ ~r|/AF \[\d+ 0 R 7 0 R\]|
      assert length(Regex.scan(~r|/AF\s*\[|, catalog)) == 1
    end

    test "leaves an existing /PageMode alone" do
      base = TestPDF.base(catalog_extra: "/PageMode /UseOutlines")
      {:ok, out} = Facturx.generate(base, @xml)

      catalog = last_catalog(out)
      assert catalog =~ "/PageMode /UseOutlines"
      refute catalog =~ "/UseAttachments"
    end

    test "refuses an indirect /Names rather than corrupting it" do
      base = TestPDF.base(catalog_extra: "/Names 7 0 R", extra_objects: [{7, "<< >>"}])

      assert Facturx.generate(base, @xml) == {:error, :names_indirect_unsupported}
    end

    test "refuses an indirect /AF rather than corrupting it" do
      base = TestPDF.base(catalog_extra: "/AF 7 0 R", extra_objects: [{7, "[]"}])

      assert Facturx.generate(base, @xml) == {:error, :af_indirect_unsupported}
    end

    test "refuses to re-embed into its own output" do
      {:ok, out} = Facturx.generate(TestPDF.base(), @xml)

      assert Facturx.generate(out, @xml) == {:error, :already_has_embedded_files}
    end
  end

  describe "input contract" do
    test "refuses a PDF that is not PDF/A at all" do
      assert Facturx.generate(TestPDF.base(part: nil), @xml) == {:error, :not_pdfa}
    end

    test "refuses PDF/A-1, which forbids embedded files" do
      assert Facturx.generate(TestPDF.base(part: 1), @xml) ==
               {:error, {:unsupported_pdfa, "PDF/A-1"}}
    end

    # `embed/3` promises `{:ok, binary()} | {:error, term()}`. It used to break
    # that promise on a malformed dictionary — `raise "unbalanced dictionary"`,
    # and a MatchError when no `<<` followed the trailer at all.
    test "an unbalanced dictionary is an error, not an exception" do
      pdf = String.replace(TestPDF.base(), "] >>\nstartxref", "]\nstartxref")

      assert {:error, _} = Facturx.generate(pdf, @xml)
    end

    test "a trailer with no dictionary at all is an error, not an exception" do
      base = TestPDF.base()
      {s, _} = :binary.match(base, "trailer")
      pdf = binary_part(base, 0, s) <> "trailer\nstartxref\n0\n%%EOF\n"

      assert {:error, _} = Facturx.generate(pdf, @xml)
    end

    property "no byte string, however malformed, ever raises" do
      base = TestPDF.base()

      check all(
              cut <- integer(0..byte_size(base)),
              junk <- binary(max_length: 40)
            ) do
        pdf = binary_part(base, 0, cut) <> junk

        assert match?({:ok, _}, Facturx.generate(pdf, @xml)) or
                 match?({:error, _}, Facturx.generate(pdf, @xml))

        assert match?({:ok, _}, Facturx.extract(pdf)) or
                 match?({:error, _}, Facturx.extract(pdf))
      end
    end

    test "refuses an encrypted PDF on both paths" do
      pdf = encrypted(TestPDF.base())

      assert Facturx.generate(pdf, @xml) == {:error, :encrypted_pdf_unsupported}
      # Not :no_embedded_file — an encrypted file may well carry an attachment,
      # it is simply out of reach.
      assert Facturx.extract(pdf) == {:error, :encrypted_pdf_unsupported}
    end

    test "a file decrypted by an incremental update is readable again" do
      # Only the *last* trailer is the document's. An earlier one belongs to a
      # revision this file has superseded, so an /Encrypt left behind there no
      # longer applies — and reading it would refuse a file that is fine.
      {:ok, facturx} = Facturx.generate(TestPDF.base(), @xml)

      once_encrypted =
        encrypted(facturx) <> "trailer\n<< /Size 12 /Root 1 0 R >>\nstartxref\n0\n%%EOF\n"

      refute Facturx.PDF.encrypted?(once_encrypted)
      assert {:ok, %{xml: @xml}} = Facturx.extract(once_encrypted)
    end

    test "refuses an encrypted PDF that does carry a reachable-looking attachment" do
      # The case that matters, and the one a check placed after the pipeline
      # would miss entirely: encryption covers strings and stream *data*, never
      # the object structure. So /EF, /AFRelationship and the object numbers
      # stay plaintext, the whole lookup succeeds, and what comes back is
      # ciphertext presented as an invoice.
      {:ok, facturx} = Facturx.generate(TestPDF.base(), @xml)

      assert Facturx.extract(encrypted(facturx)) == {:error, :encrypted_pdf_unsupported}
    end

    test "refuses an encrypted PDF that names its /Encrypt dictionary inline" do
      pdf =
        String.replace(
          TestPDF.base(),
          "trailer\n<< /Size",
          "trailer\n<< /Encrypt << /Filter /Standard /V 2 >> /Size"
        )

      assert Facturx.generate(pdf, @xml) == {:error, :encrypted_pdf_unsupported}
    end

    test "the word \"encrypt\" in the document is not read as encryption" do
      pdf = TestPDF.base(title: "Guide de chiffrement /Encrypt expliqué")

      assert {:ok, _} = Facturx.generate(pdf, @xml)
    end

    test "a document quoting the /Encrypt syntax itself is not read as encryption" do
      # The shape the regex looks for, verbatim, inside an uncompressed XMP
      # packet. Only a trailer dictionary declares encryption, so a scan of the
      # whole file would refuse a perfectly readable document here.
      pdf = TestPDF.base(title: "spec: /Encrypt << /Filter /Standard >>")

      refute Facturx.PDF.encrypted?(pdf)
      assert {:ok, _} = Facturx.generate(pdf, @xml)
    end

    test "a file with neither a trailer nor a cross-reference stream is refused" do
      base = TestPDF.base()
      {s, _} = :binary.match(base, "\nxref")
      pdf = binary_part(base, 0, s) <> "\nstartxref\n0\n%%EOF\n"

      assert Facturx.generate(pdf, @xml) == {:error, :no_trailer}
    end
  end

  describe "extract/1" do
    test "reports a plain PDF/A as carrying no embedded file" do
      assert Facturx.extract(TestPDF.base()) == {:error, :no_embedded_file}
    end

    test "returns nil as the profile when the guideline URN is unknown" do
      {:ok, out} = Facturx.generate(TestPDF.base(), "<rsm:CrossIndustryInvoice/>")

      assert {:ok, %{profile: nil}} = Facturx.extract(out)
    end
  end

  # A base declaring encryption, in the usual indirect form.
  defp encrypted(pdf) do
    String.replace(pdf, "trailer\n<< /Size", "trailer\n<< /Encrypt 9 0 R /Size")
  end

  # The entries of the cross-reference *stream* the update appended, as
  # `%{number => offset}`. `/W [1 4 2]` and `/Index` are what this library
  # writes; nothing here tries to be a general reader.
  defp last_xref_stream(pdf) do
    # `startxref` points at the object, whose dictionary opens after its header —
    # searching forward from `/Type /XRef` would land past the `<<`.
    [_, offset] = Regex.scan(~r/startxref\s+(\d+)/, pdf) |> List.last()
    s = String.to_integer(offset)
    {:ok, dict} = Facturx.PDF.balanced_dict(pdf, s)
    [_, index] = Regex.run(~r/\/Index \[([^\]]*)\]/, dict)

    numbers =
      index
      |> String.split()
      |> Enum.map(&String.to_integer/1)
      |> Enum.chunk_every(2)
      |> Enum.flat_map(fn [first, count] -> Enum.to_list(first..(first + count - 1)) end)

    {:ok, raw} = Facturx.PDF.stream_bytes({binary_part(pdf, s, byte_size(pdf) - s), :truncated})
    {:ok, data} = Facturx.PDF.inflate(raw)

    numbers
    |> Enum.zip(for <<1, offset::32, 0::16 <- data>>, do: offset)
    |> Map.new()
  end

  # The catalog as the update left it: the *last* definition of object 1 wins.
  # The lookbehind matters — without it this also matches inside `11 0 obj`.
  defp last_catalog(pdf) do
    ~r/(?<!\d)1 0 obj\s*(<<.*?>>)\s*endobj/s
    |> Regex.scan(pdf)
    |> List.last()
    |> Enum.at(1)
  end

  # The first payload whose deflate stream contains `needle` literally. Deflate
  # falls back to stored blocks on incompressible input, so high-entropy filler
  # is what makes this findable at all.
  defp xml_deflating_with(needle) do
    Enum.find_value(1..200, fn n ->
      filler = for i <- 1..n, into: <<>>, do: :crypto.hash(:sha256, <<i::32, n::32>>)
      xml = "<a>" <> filler <> needle <> "</a>"
      if :binary.match(:zlib.compress(xml), needle) != :nomatch, do: xml
    end) || flunk("no payload found whose deflate stream contains #{needle}")
  end

  # The first payload whose deflate stream ends on `byte`. Searched rather than
  # hard-coded: the exact length depends on the zlib build.
  defp xml_deflating_to(byte) do
    Enum.find_value(1..2000, fn n ->
      xml = "<a>" <> String.duplicate("ab", n) <> "c</a>"
      if :binary.last(:zlib.compress(xml)) == byte, do: xml
    end) || flunk("no payload found whose deflate stream ends on #{byte}")
  end

  defp base_with_metadata_ending_on(byte) do
    Enum.find_value(1..2000, fn n ->
      base = TestPDF.base(compress_xmp: true, title: String.duplicate("ab", n))
      if :binary.last(TestPDF.metadata_stream(base)) == byte, do: base
    end) || flunk("no base found whose deflated /Metadata ends on #{byte}")
  end
end
