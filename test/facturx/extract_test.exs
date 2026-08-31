defmodule Facturx.ExtractTest do
  use ExUnit.Case, async: true

  alias Facturx.TestPDF

  @local Path.expand("../fixtures/local/facturx-en16931.pdf", __DIR__)

  defp cii(urn) do
    ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
      ~s(<rsm:CrossIndustryInvoice xmlns:rsm="urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100" xmlns:ram="urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:100">) <>
      "<rsm:ExchangedDocumentContext><ram:GuidelineSpecifiedDocumentContextParameter>" <>
      "<ram:ID>#{urn}</ram:ID>" <>
      "</ram:GuidelineSpecifiedDocumentContextParameter></rsm:ExchangedDocumentContext>" <>
      "</rsm:CrossIndustryInvoice>"
  end

  describe "the embedded file it picks" do
    test "recognises each of the known payload names" do
      for name <- ~w(factur-x.xml zugferd-invoice.xml order-x.xml) do
        {:ok, pdf} =
          Facturx.generate(TestPDF.base(), cii("urn:cen.eu:en16931:2017"), filename: name)

        assert {:ok, %{filename: ^name}} = Facturx.extract(pdf)
      end
    end

    test "falls back to the only /EF-bearing filespec when the name is unknown" do
      {:ok, pdf} =
        Facturx.generate(TestPDF.base(), cii("urn:cen.eu:en16931:2017"), filename: "invoice.xml")

      assert {:ok, %{filename: "invoice.xml", profile: :en16931}} = Facturx.extract(pdf)
    end
  end

  describe "profile detection" do
    test "reads the profile back from the guideline URN, for all five" do
      for profile <- Facturx.profiles() do
        urn = Facturx.Profile.to_urn(profile)
        {:ok, pdf} = Facturx.generate(TestPDF.base(), cii(urn))

        assert {:ok, %{profile: ^profile}} = Facturx.extract(pdf)
      end
    end
  end

  describe "inputs it cannot read" do
    # Each must be an error tuple. Extract works on raw bytes, so the failure
    # mode to guard against is an exception reaching the caller, not a wrong
    # answer.
    test "a PDF carrying no embedded file" do
      assert Facturx.extract(TestPDF.base()) == {:error, :no_embedded_file}
    end

    test "bytes that are not a PDF at all" do
      assert {:error, _} = Facturx.extract("not a pdf, not even close")
      assert {:error, _} = Facturx.extract(<<0, 1, 2, 3, 255>>)
      assert {:error, _} = Facturx.extract("")
    end

    test "a Factur-X PDF truncated at any point never raises" do
      xml = cii("urn:cen.eu:en16931:2017")
      {:ok, pdf} = Facturx.generate(TestPDF.base(), xml)

      # Cuts through the xref, the stream, the dictionary, the object header.
      # A prefix is not necessarily unreadable — Extract indexes objects by
      # scanning for `N G obj` and never consults the table, so a file cut after
      # the payload object still yields the whole attachment, which is the point
      # of scanning. What must never happen is an exception reaching the caller.
      for cut <- 1..byte_size(pdf)//97 do
        case Facturx.extract(binary_part(pdf, 0, cut)) do
          # When a prefix does read, it must read the whole payload — never a
          # partial one, which is the failure a length bug would produce.
          {:ok, %{xml: got}} -> assert got == xml
          {:error, _} -> :ok
        end
      end
    end
  end

  describe "extract/1 (real Factur-X fixture)" do
    @describetag :local

    setup do
      unless File.exists?(@local), do: raise("missing local fixture: #{@local}")
      {:ok, pdf: File.read!(@local)}
    end

    test "returns the complete, well-formed embedded CII XML", %{pdf: pdf} do
      assert {:ok, %{xml: xml, filename: name, profile: profile}} = Facturx.extract(pdf)

      assert name == "factur-x.xml"
      assert String.starts_with?(xml, "<?xml")
      # Prove the whole document was extracted, not a truncated deflate block.
      assert xml |> String.trim_trailing() |> String.ends_with?("</rsm:CrossIndustryInvoice>")
      # And that it actually parses as XML (guards against silent corruption).
      assert {:ok, _tree} = Saxy.SimpleForm.parse_string(xml)
      assert profile in Facturx.profiles()
    end

    test "returned xml is detached from the source PDF binary", %{pdf: pdf} do
      {:ok, %{xml: xml}} = Facturx.extract(pdf)
      # A :binary.copy'd result must be far smaller than the multi-MB PDF and
      # must not retain it as a referenced (sub)binary.
      assert byte_size(xml) < byte_size(pdf)
      assert :binary.referenced_byte_size(xml) == byte_size(xml)
    end
  end
end
