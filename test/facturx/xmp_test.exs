defmodule Facturx.XmpTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Facturx.Xmp

  @element_xmp ~s(<x:xmpmeta><rdf:RDF><rdf:Description rdf:about=""><pdfaExtension:schemas><rdf:Bag></rdf:Bag></pdfaExtension:schemas><pdfaid:part>2</pdfaid:part></rdf:Description></rdf:RDF></x:xmpmeta>)

  @attribute_xmp ~s(<x:xmpmeta><rdf:RDF><rdf:Description rdf:about="" pdfaid:part="2" pdfaid:conformance="B"></rdf:Description></rdf:RDF></x:xmpmeta>)

  test "promotes pdfaid:part 2 -> 3 in element form" do
    out = Xmp.promote(@element_xmp, :en16931, "factur-x.xml")
    assert out =~ "<pdfaid:part>3</pdfaid:part>"
    refute out =~ "<pdfaid:part>2</pdfaid:part>"
  end

  test "promotes pdfaid:part 2 -> 3 in compact attribute form" do
    out = Xmp.promote(@attribute_xmp, :en16931, "factur-x.xml")
    assert out =~ ~s(pdfaid:part="3")
    refute out =~ ~s(pdfaid:part="2")
  end

  test "declares the Factur-X extension schema and fx:* properties" do
    out = Xmp.promote(@element_xmp, :en16931, "factur-x.xml")
    assert out =~ "urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0#"
    assert out =~ "<fx:ConformanceLevel>EN 16931</fx:ConformanceLevel>"
    assert out =~ "<fx:DocumentFileName>factur-x.xml</fx:DocumentFileName>"
  end

  test "XML-escapes the embedded filename" do
    out = Xmp.promote(@element_xmp, :en16931, "a&b<c>.xml")
    assert out =~ "<fx:DocumentFileName>a&amp;b&lt;c&gt;.xml</fx:DocumentFileName>"
    refute out =~ "a&b<c>.xml"
  end

  test "conformance_level/1 maps every profile" do
    assert Xmp.conformance_level(:minimum) == "MINIMUM"
    assert Xmp.conformance_level(:basic) == "BASIC"
    assert Xmp.conformance_level(:en16931) == "EN 16931"
    assert Xmp.conformance_level(:extended) == "EXTENDED"
  end

  describe "properties" do
    # The filename reaches the XMP as element content, and reaches the PDF as a
    # /Filespec name. Neither path escapes it for the caller, so the promotion
    # has to.
    # `string(:printable)` alone would only sometimes draw the characters that
    # matter, so the metacharacters are spliced in on purpose.
    defp filename do
      gen all(
            stem <- string(:printable, min_length: 1, max_length: 12),
            nasty <- string(Enum.concat([?a..?z, [?<, ?>, ?&, ?", ?', ?\s]]), max_length: 6),
            ext <- member_of([".xml", ".XML", ""])
          ) do
        stem <> nasty <> ext
      end
    end

    property "promotion is idempotent for any profile and filename" do
      check all(
              profile <- member_of(Facturx.profiles()),
              name <- filename()
            ) do
        once = Xmp.promote(@element_xmp, profile, name)
        assert Xmp.promote(once, profile, name) == once
      end
    end

    property "the promoted packet stays well-formed XML for any filename" do
      check all(name <- filename()) do
        out = Xmp.promote(@element_xmp, :en16931, name)

        assert {:ok, _} = Saxy.SimpleForm.parse_string(out)
      end
    end
  end
end
