defmodule Facturx.Xmp do
  @moduledoc """
  Promote a base PDF/A XMP packet into a Factur-X / ZUGFeRD one.

  Given the document-level XMP of a valid PDF/A-2 (or already-A-3) file, this:

    * bumps `pdfaid:part` 2 → 3 (conformance level preserved);
    * declares the Factur-X extension schema in `pdfaExtension:schemas`
      (namespace `urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0#`,
      prefix `fx`) — required so veraPDF accepts the `fx:*` properties;
    * adds the `fx:*` properties (`DocumentType`, `DocumentFileName`,
      `Version`, `ConformanceLevel`).

  The transformation is idempotent: re-promoting an already-Factur-X XMP is a
  no-op for the parts that already exist.
  """

  @fx_ns "urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0#"
  @fx_version "1.0"

  @doc "Promote `xmp` for the given `profile` and embedded `filename`."
  @spec promote(binary(), Facturx.profile(), String.t()) :: binary()
  def promote(xmp, profile, filename \\ "factur-x.xml") do
    xmp
    |> bump_part()
    |> ensure_extension_schema()
    |> ensure_fx_description(profile, filename)
  end

  # --- pdfaid:part 2 -> 3 ---------------------------------------------------

  # Handle both the element form (<pdfaid:part>2</pdfaid:part>) and the compact
  # attribute form (pdfaid:part="2") that Adobe-style writers emit.
  defp bump_part(xmp) do
    xmp
    |> then(&Regex.replace(~r{(<pdfaid:part>\s*)2(\s*</pdfaid:part>)}, &1, "\\g{1}3\\g{2}"))
    |> then(&Regex.replace(~r{(pdfaid:part\s*=\s*["'])2(["'])}, &1, "\\g{1}3\\g{2}"))
  end

  # --- Factur-X extension schema declaration --------------------------------

  defp ensure_extension_schema(xmp) do
    cond do
      String.contains?(xmp, @fx_ns) ->
        xmp

      Regex.match?(~r|</rdf:Bag>\s*</pdfaExtension:schemas>|, xmp) ->
        # Insert our schema li into the existing extension-schemas bag.
        String.replace(
          xmp,
          ~r|</rdf:Bag>\s*</pdfaExtension:schemas>|,
          fx_schema_li() <> "</rdf:Bag></pdfaExtension:schemas>",
          global: false
        )

      true ->
        # No extension-schemas block yet: add a full one before </rdf:RDF>.
        block =
          ~s(<rdf:Description rdf:about="" xmlns:pdfaExtension="http://www.aiim.org/pdfa/ns/extension/" xmlns:pdfaSchema="http://www.aiim.org/pdfa/ns/schema#" xmlns:pdfaProperty="http://www.aiim.org/pdfa/ns/property#"><pdfaExtension:schemas><rdf:Bag>) <>
            fx_schema_li() <> "</rdf:Bag></pdfaExtension:schemas></rdf:Description>"

        String.replace(xmp, "</rdf:RDF>", block <> "</rdf:RDF>", global: false)
    end
  end

  defp fx_schema_li do
    ~s(<rdf:li rdf:parseType="Resource"><pdfaSchema:schema>Factur-X PDFA Extension Schema</pdfaSchema:schema><pdfaSchema:namespaceURI>#{@fx_ns}</pdfaSchema:namespaceURI><pdfaSchema:prefix>fx</pdfaSchema:prefix><pdfaSchema:property><rdf:Seq>) <>
      property_li("DocumentFileName", "The name of the embedded XML document") <>
      property_li("DocumentType", "INVOICE or ORDER") <>
      property_li(
        "Version",
        "The actual version of the standard applying to the embedded XML document"
      ) <>
      property_li("ConformanceLevel", "The conformance level of the embedded XML document") <>
      "</rdf:Seq></pdfaSchema:property></rdf:li>"
  end

  defp property_li(name, desc) do
    ~s(<rdf:li rdf:parseType="Resource"><pdfaProperty:name>#{name}</pdfaProperty:name><pdfaProperty:valueType>Text</pdfaProperty:valueType><pdfaProperty:category>external</pdfaProperty:category><pdfaProperty:description>#{desc}</pdfaProperty:description></rdf:li>)
  end

  # --- fx:* property values -------------------------------------------------

  defp ensure_fx_description(xmp, profile, filename) do
    if String.contains?(xmp, ~s(xmlns:fx=")) do
      xmp
    else
      desc =
        ~s(<rdf:Description rdf:about="" xmlns:fx="#{@fx_ns}">) <>
          "<fx:DocumentType>INVOICE</fx:DocumentType>" <>
          "<fx:DocumentFileName>#{xml_escape(filename)}</fx:DocumentFileName>" <>
          "<fx:Version>#{@fx_version}</fx:Version>" <>
          "<fx:ConformanceLevel>#{conformance_level(profile)}</fx:ConformanceLevel>" <>
          "</rdf:Description>"

      String.replace(xmp, "</rdf:RDF>", desc <> "</rdf:RDF>", global: false)
    end
  end

  defp xml_escape(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  @doc "The `fx:ConformanceLevel` string for a Factur-X profile."
  @spec conformance_level(Facturx.profile()) :: String.t()
  def conformance_level(:minimum), do: "MINIMUM"
  def conformance_level(:basic_wl), do: "BASIC WL"
  def conformance_level(:basic), do: "BASIC"
  def conformance_level(:en16931), do: "EN 16931"
  def conformance_level(:extended), do: "EXTENDED"
end
