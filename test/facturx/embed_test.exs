defmodule Facturx.EmbedTest do
  use ExUnit.Case, async: true

  @h Path.expand("../fixtures/local/harness", __DIR__)
  @base Path.join(@h, "base.pdf")
  @cii Path.join(@h, "cii.xml")
  @verapdf System.find_executable("verapdf")

  describe "embed/generate against a real PDF/A-2b base" do
    @describetag :local

    setup do
      for f <- [@base, @cii], do: File.exists?(f) || raise("missing fixture: #{f}")
      {:ok, base: File.read!(@base), xml: File.read!(@cii)}
    end

    test "produces a Factur-X whose embedded XML round-trips", %{base: base, xml: xml} do
      assert {:ok, out} = Facturx.generate(base, xml, profile: :en16931)
      assert byte_size(out) > byte_size(base)

      assert {:ok, %{xml: got, filename: "factur-x.xml", profile: :en16931}} =
               Facturx.extract(out)

      assert got == xml
    end

    test "promotes the XMP to PDF/A-3 with the Factur-X extension schema", %{base: base, xml: xml} do
      {:ok, out} = Facturx.generate(base, xml, profile: :en16931)

      # The active (overridden) Metadata object carries part 3. Note: an
      # incremental update keeps the original part-2 XMP earlier in the bytes;
      # readers resolve the latest object via the new xref (veraPDF confirms).
      assert out =~ "<pdfaid:part>3</pdfaid:part>"
      assert out =~ "urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0#"
      assert out =~ "<fx:DocumentType>INVOICE</fx:DocumentType>"
      assert out =~ "<fx:ConformanceLevel>EN 16931</fx:ConformanceLevel>"
      assert out =~ "/AFRelationship /Data"
    end

    # Runs only where veraPDF is installed; the authoritative conformance oracle.
    if @verapdf do
      test "output is a valid PDF/A-3b document (veraPDF)", %{base: base, xml: xml} do
        {:ok, out} = Facturx.generate(base, xml)

        tmp =
          Path.join(System.tmp_dir!(), "facturx_embed_#{System.unique_integer([:positive])}.pdf")

        File.write!(tmp, out)

        {report, _status} = System.cmd(@verapdf, ["-f", "3b", tmp], stderr_to_stdout: true)
        File.rm(tmp)

        assert report =~ ~s(isCompliant="true"), report
        assert report =~ ~s(failedRules="0")
      end
    end
  end

  describe "catalog merge robustness" do
    @describetag :local

    @withnames Path.join(@h, "withnames.pdf")

    test "merges into a base that already has a /Names dict (no duplicate keys)" do
      unless File.exists?(@withnames), do: raise("missing fixture: #{@withnames}")
      base = File.read!(@withnames)
      xml = File.read!(@cii)

      assert {:ok, out} = Facturx.generate(base, xml, profile: :en16931)
      # merged, not appended: a single /Names entry that keeps /Dests and gains
      # /EmbeddedFiles.
      assert {:ok, %{xml: ^xml}} = Facturx.extract(out)
      assert out =~ "/EmbeddedFiles"
      assert out =~ "/Dests"

      if @verapdf do
        tmp =
          Path.join(System.tmp_dir!(), "facturx_names_#{System.unique_integer([:positive])}.pdf")

        File.write!(tmp, out)
        {report, _} = System.cmd(@verapdf, ["-f", "3b", tmp], stderr_to_stdout: true)
        File.rm(tmp)
        assert report =~ ~s(isCompliant="true"), report
      end
    end

    test "refuses (does not corrupt) a base that already carries embedded files" do
      golden = Path.expand("../fixtures/local/facturx-en16931.pdf", __DIR__)

      if File.exists?(golden) do
        assert {:error, reason} = Facturx.generate(File.read!(golden), File.read!(@cii))

        assert reason in [
                 :already_has_embedded_files,
                 :af_indirect_unsupported,
                 :names_indirect_unsupported
               ]
      end
    end
  end

  # Tagged, not guarded by File.exists?: an `if` around the only assertion makes
  # the test report green everywhere the fixture is missing. The contract itself
  # is covered synthetically in Facturx.PdfRoundtripTest; this pins it against a
  # real producer's output.
  @tag :local
  test "rejects a non-PDF/A input" do
    plain = Path.expand("../fixtures/local/plain-typst.pdf", __DIR__)

    assert Facturx.generate(File.read!(plain), "<xml/>") == {:error, :not_pdfa}
  end

  test "rejects an unsupported PDF/A-1 base" do
    # Minimal stub declaring PDF/A-1 in its XMP; enough to hit the contract check.
    fake =
      "%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Metadata 2 0 R >>\nendobj\n" <>
        "2 0 obj\n<< /Type /Metadata /Subtype /XML /Length 24 >>\nstream\n" <>
        "<pdfaid:part>1</pdfaid:part>\nendstream\nendobj\n" <>
        "trailer\n<< /Root 1 0 R /Size 3 >>\nstartxref\n0\n%%EOF"

    assert Facturx.generate(fake, "<xml/>") == {:error, {:unsupported_pdfa, "PDF/A-1"}}
  end
end
