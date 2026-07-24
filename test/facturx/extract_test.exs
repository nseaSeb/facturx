defmodule Facturx.ExtractTest do
  use ExUnit.Case, async: true

  @local Path.expand("../fixtures/local/facturx-en16931.pdf", __DIR__)

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
      assert profile in [:minimum, :basic_wl, :basic, :en16931, :extended]
    end

    test "returned xml is detached from the source PDF binary", %{pdf: pdf} do
      {:ok, %{xml: xml}} = Facturx.extract(pdf)
      # A :binary.copy'd result must be far smaller than the multi-MB PDF and
      # must not retain it as a referenced (sub)binary.
      assert byte_size(xml) < byte_size(pdf)
      assert :binary.referenced_byte_size(xml) == byte_size(xml)
    end
  end

  test "extract/1 errors cleanly when there is no embedded file" do
    plain = Path.expand("../fixtures/local/plain-typst.pdf", __DIR__)

    if File.exists?(plain) do
      assert {:error, :no_embedded_file} = Facturx.extract(File.read!(plain))
    end
  end
end
